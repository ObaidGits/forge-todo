import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'migration_fixtures.dart';

/// Wave 12 release gate (task 12.6): **safety-generation** automation.
///
/// Every incompatible migration first produces a mandatory old-client-
/// compatible safety backup (data-model §5.2, design §12). This suite drives
/// the real [GenerationMigrator] through an incompatible (shadow) migration and
/// proves the pre-migration safety generation is (a) created, and (b) genuinely
/// restorable: the previously installed app can reopen the backed-up store at
/// its original schema version with every row intact. It reuses the migration
/// harness and safety-backup engine rather than forking them.
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-SAFETY-GENERATION-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.6'),
  requirements: <RequirementId>[
    RequirementId('NFR-MAIN-004'),
    RequirementId('NFR-REL-002'),
  ],
);

final class _SeqIds implements IdGenerator {
  int _n = 0;

  @override
  String uuidV7() {
    _n += 1;
    return 'gen${_n.toString().padLeft(4, '0')}';
  }
}

void main() {
  late Directory root;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late FakeDiskSpaceProbe probe;
  late ActiveGenerationPointer pointer;
  const String sourceDirName = 'generation-source';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-safety-gen-');
    layout = MigrationLayout(baseDirectory: root.path);
    opener = Sqlite3MigrationConnectionOpener();
    probe = FakeDiskSpaceProbe(8 * 1024 * 1024 * 1024);
    pointer = ActiveGenerationPointer(pointerFile: layout.pointerFile);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> bootstrapSource({int items = 20}) async {
    final MigrationConnection conn = await opener.open(
      layout.generationDirectory(sourceDirName),
      createIfMissing: true,
    );
    await createV1Schema(conn);
    await seedV1(conn, items: items);
    await conn.dispose();
    await pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId('gen-source'),
          schemaVersion: 1,
        ),
        directoryName: sourceDirName,
      ),
    );
  }

  GenerationMigrator migrator() => GenerationMigrator(
    layout: layout,
    opener: opener,
    registry: buildRegistry(),
    preflight: DiskSpacePreflight(probe),
    safetyBackup: SafetyBackup(now: () => DateTime.utc(2024, 1, 1)),
    verifier: const MigrationVerifier(),
    idGenerator: _SeqIds(),
  );

  testWithEvidence(
    _evidence('CREATED'),
    'an incompatible migration creates a manifest-finalised safety backup at '
    'the pre-migration schema version',
    () async {
      await bootstrapSource();
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 3,
      );

      final SafetyBackupRecord? backup = outcome.safetyBackup;
      expect(backup, isNotNull);
      expect(backup!.schemaVersion, 1, reason: 'pre-migration version');
      final Directory backupDir = Directory(backup.directoryPath);
      expect(backupDir.existsSync(), isTrue);
      // The manifest sentinel proves the copy completed.
      final File manifest = File('${backupDir.path}/backup_manifest.json');
      expect(manifest.existsSync(), isTrue);
      final Map<String, Object?> json =
          jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
      expect(json['schema_version'], 1);
      expect(json['file_names'], contains('store.sqlite'));
    },
  );

  testWithEvidence(
    _evidence('RESTORABLE'),
    'the safety backup is restorable: the prior app reopens it at its original '
    'schema version with every row intact',
    () async {
      await bootstrapSource(items: 20);
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 3,
      );
      final SafetyBackupRecord backup = outcome.safetyBackup!;

      // Simulate the previously installed (v1) app reopening the safety copy.
      // The old app understands the v1 schema, so it reads the original
      // `title` column and the original row set unchanged.
      final MigrationConnection restored = await opener.open(
        backup.directoryPath,
        createIfMissing: false,
      );
      try {
        final List<Map<String, Object?>> integrity = await restored.select(
          'PRAGMA integrity_check',
        );
        expect(integrity.first.values.first, 'ok');
        expect(await restored.countRows('items'), 20);
        expect(await restored.countRows('item_events'), 20);
        final int recordedVersion = await restored.scalarInt(
          'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
        );
        expect(recordedVersion, 1, reason: 'old-client-compatible version');
        // The v1 `title` column is present (not the migrated `name` column),
        // confirming this is the pre-migration shape a prior client can open.
        final int titled = await restored.scalarInt(
          "SELECT COUNT(*) AS n FROM items WHERE title = 'Title 0'",
        );
        expect(titled, 1);
      } finally {
        await restored.dispose();
      }

      // The upgraded live generation is independent and at v3.
      final ActiveGenerationRecord? live = await pointer.read();
      expect(live!.generation.schemaVersion, 3);
      expect(live.directoryName, isNot(sourceDirName));
    },
  );

  testWithEvidence(
    _evidence('INDEPENDENT'),
    'the safety backup survives untouched after the migration activates the '
    'new generation, so recovery remains possible post-upgrade',
    () async {
      await bootstrapSource(items: 8);
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 3,
      );
      final SafetyBackupRecord backup = outcome.safetyBackup!;
      final Directory backupDir = Directory(backup.directoryPath);

      // The safety backup lives under the backup root, outside every
      // generation directory, so activating/discarding generations never
      // touches it.
      expect(backupDir.path, startsWith(layout.backupRoot.path));
      expect(backupDir.existsSync(), isTrue);
      final File store = File('${backupDir.path}/store.sqlite');
      expect(store.existsSync(), isTrue);
      expect(await store.length(), greaterThan(0));
    },
  );
}
