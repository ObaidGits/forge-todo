import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_journal.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'migration_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-GENERATION-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

/// Sequential id generator so generation directory names are deterministic.
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
    root = await Directory.systemTemp.createTemp('forge-migrate-');
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

  Future<void> bootstrapSource({int items = 25}) async {
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

  GenerationMigrator migrator({
    MigrationRegistry? registry,
    MigrationVerifier verifier = const MigrationVerifier(),
  }) => GenerationMigrator(
    layout: layout,
    opener: opener,
    registry: registry ?? buildRegistry(),
    preflight: DiskSpacePreflight(probe),
    safetyBackup: SafetyBackup(now: () => DateTime.utc(2024, 1, 1)),
    verifier: verifier,
    idGenerator: _SeqIds(),
  );

  testWithEvidence(
    _evidence('001'),
    'an all-additive path upgrades the live store transactionally in place',
    () async {
      await bootstrapSource();
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 2,
      );
      expect(outcome.result, MigrationResult.appliedInPlace);
      expect(outcome.activeDirectoryName, sourceDirName);

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 2);
      expect(p.directoryName, sourceDirName);

      final MigrationConnection conn = await opener.open(
        layout.generationDirectory(sourceDirName),
        createIfMissing: false,
      );
      final int withPriority = await conn.scalarInt(
        'SELECT COUNT(*) AS n FROM items WHERE priority = 0',
      );
      await conn.dispose();
      expect(withPriority, 25);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'an incompatible path builds and atomically activates a verified shadow '
    'generation while preserving the prior generation',
    () async {
      await bootstrapSource();
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 3,
      );

      expect(outcome.result, MigrationResult.activatedShadowGeneration);
      expect(outcome.safetyBackup, isNotNull);
      expect(outcome.diskEstimate, isNotNull);
      expect(outcome.rowsBackfilled, greaterThan(0));
      expect(outcome.activeDirectoryName, isNot(sourceDirName));

      // Pointer now targets the new, verified generation at v3.
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 3);
      expect(p.directoryName, outcome.activeDirectoryName);

      // New generation holds the transformed data.
      final MigrationConnection shadow = await opener.open(
        layout.generationDirectory(p.directoryName),
        createIfMissing: false,
      );
      final int items = await shadow.countRows('items');
      final int openStatus = await shadow.scalarInt(
        "SELECT COUNT(*) AS n FROM items WHERE status = 'open'",
      );
      final int named = await shadow.scalarInt(
        "SELECT COUNT(*) AS n FROM items WHERE name = 'Title 0'",
      );
      await shadow.dispose();
      expect(items, 25);
      expect(openStatus, 25);
      expect(named, 1);

      // The prior generation is untouched and still openable (rollback safety).
      final MigrationConnection old = await opener.open(
        layout.generationDirectory(sourceDirName),
        createIfMissing: false,
      );
      final int oldTitles = await old.scalarInt(
        'SELECT COUNT(*) AS n FROM items',
      );
      await old.dispose();
      expect(oldTitles, 25);

      // The safety backup is an old-version-compatible copy.
      expect(
        Directory(outcome.safetyBackup!.directoryPath).existsSync(),
        isTrue,
      );
    },
  );

  testWithEvidence(
    _evidence('003'),
    'a single incompatible step from a baseline activates a shadow generation',
    () async {
      await bootstrapSource(items: 12);
      final MigrationRegistry single = MigrationRegistry(<MigrationPlan>[
        incompatibleV1toV3Direct(),
      ]);
      final MigrationOutcome outcome = await migrator(
        registry: single,
      ).migrateToTarget(targetSchemaVersion: 2);
      expect(outcome.result, MigrationResult.activatedShadowGeneration);

      final ActiveGenerationRecord? p = await pointer.read();
      final MigrationConnection conn = await opener.open(
        layout.generationDirectory(p!.directoryName),
        createIfMissing: false,
      );
      expect(await conn.countRows('items'), 12);
      expect(await conn.countRows('item_events'), 12);
      await conn.dispose();
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a disk-space shortfall aborts before any backup or shadow is created and '
    'leaves the prior generation live',
    () async {
      await bootstrapSource();
      probe.available = 1024; // Far below the estimate.
      await expectLater(
        migrator().migrateToTarget(targetSchemaVersion: 3),
        throwsA(
          isA<MigrationFailure>().having(
            (MigrationFailure e) => e.phase,
            'phase',
            'preflight',
          ),
        ),
      );
      // Pointer unchanged; no backup or shadow directory produced.
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 1);
      expect(p.directoryName, sourceDirName);
      expect(layout.backupRoot.existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('005'),
    'a failed verification rolls back: pointer stays at the source and shadow '
    'directories are cleaned up',
    () async {
      await bootstrapSource();
      await expectLater(
        migrator(
          verifier: _AlwaysFailVerifier(),
        ).migrateToTarget(targetSchemaVersion: 3),
        throwsA(isA<MigrationFailure>()),
      );

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 1);
      expect(p.directoryName, sourceDirName);

      // Only the source generation directory and backups remain; no shadow.
      final List<String> dirs = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(dirs, <String>[sourceDirName]);
      // The migration journal was cleared.
      expect(layout.journalFile.existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('006'),
    'a broken transform aborts the build and preserves the prior generation',
    () async {
      await bootstrapSource();
      // Target schema requires NOT NULL name, but the transform omits it.
      final MigrationRegistry broken = MigrationRegistry(<MigrationPlan>[
        MigrationPlan(
          sourceVersion: 1,
          targetVersion: 2,
          requiresShadowGeneration: true,
          buildTargetSchema: createV3Schema,
          backfillTables: <BackfillTable>[
            BackfillTable(
              name: 'items',
              orderByColumn: 'id',
              transform: (Map<String, Object?> row) => <String, Object?>{
                'id': row['id'],
                'profile_id': row['profile_id'],
                // 'name' deliberately missing -> NOT NULL violation.
                'status': 'open',
                'created_at': row['created_at'],
              },
            ),
          ],
        ),
      ]);
      await expectLater(
        migrator(registry: broken).migrateToTarget(targetSchemaVersion: 2),
        throwsA(isA<MigrationFailure>()),
      );
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 1);
      expect(p.directoryName, sourceDirName);
    },
  );

  testWithEvidence(
    _evidence('007'),
    'cleanupAbandoned deletes shadow directories left by an interrupted run '
    'without touching the pointer',
    () async {
      await bootstrapSource();
      // Simulate an interrupted migration: a shadow dir plus an un-activated
      // journal entry referencing it.
      final Directory abandoned = Directory(
        layout.generationDirectory('generation-abandoned'),
      )..createSync(recursive: true);
      File('${abandoned.path}/store.sqlite').writeAsBytesSync(<int>[0]);
      await MigrationJournal(journalFile: layout.journalFile).write(
        MigrationJournalEntry(
          sourceDirectoryName: sourceDirName,
          sourceSchemaVersion: 1,
          targetSchemaVersion: 3,
          createdDirectoryNames: <String>['generation-abandoned'],
          activated: false,
        ),
      );

      await migrator().cleanupAbandoned();

      expect(abandoned.existsSync(), isFalse);
      expect(layout.journalFile.existsSync(), isFalse);
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, sourceDirName);
      expect(p.generation.schemaVersion, 1);
    },
  );

  testWithEvidence(
    _evidence('008'),
    'requesting the current version is a no-op',
    () async {
      await bootstrapSource();
      final MigrationOutcome outcome = await migrator().migrateToTarget(
        targetSchemaVersion: 1,
      );
      expect(outcome.result, MigrationResult.upToDate);
    },
  );

  testWithEvidence(
    _evidence('009'),
    'a post-activation verification failure restores the prior pointer and '
    'discards the shadow generation',
    () async {
      await bootstrapSource(items: 5);
      // Target schema omits schema_metadata; the shadow verifies and activates,
      // but the post-switch check cannot confirm the recorded schema version,
      // so activation is rolled back.
      final MigrationRegistry noMetadata = MigrationRegistry(<MigrationPlan>[
        MigrationPlan(
          sourceVersion: 1,
          targetVersion: 2,
          requiresShadowGeneration: true,
          buildTargetSchema: (MigrationConnection c) async {
            await c.execute(
              'CREATE TABLE items ('
              'id TEXT NOT NULL PRIMARY KEY, '
              'profile_id TEXT NOT NULL, '
              'name TEXT NOT NULL, '
              'status TEXT NOT NULL, '
              'priority INTEGER NOT NULL DEFAULT 0, '
              'created_at INTEGER NOT NULL)',
            );
          },
          backfillTables: <BackfillTable>[
            BackfillTable(
              name: 'items',
              orderByColumn: 'id',
              transform: (Map<String, Object?> row) => <String, Object?>{
                'id': row['id'],
                'profile_id': row['profile_id'],
                'name': row['title'],
                'status': 'open',
                'priority': 0,
                'created_at': row['created_at'],
              },
            ),
          ],
        ),
      ]);

      await expectLater(
        migrator(registry: noMetadata).migrateToTarget(targetSchemaVersion: 2),
        throwsA(
          isA<MigrationFailure>().having(
            (MigrationFailure e) => e.phase,
            'phase',
            'post_activation_verify',
          ),
        ),
      );

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 1);
      expect(p.directoryName, sourceDirName);
      final List<String> dirs = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(dirs, <String>[sourceDirName]);
    },
  );

  testWithEvidence(
    _evidence('010'),
    'a chain ending in an additive step over a shadow generation activates '
    'with the additive change materialised',
    () async {
      await bootstrapSource(items: 8);
      // v1->v2 incompatible (rebuild to the v3 shape) then v2->v3 additive.
      final MigrationRegistry mixed = MigrationRegistry(<MigrationPlan>[
        MigrationPlan(
          sourceVersion: 1,
          targetVersion: 2,
          requiresShadowGeneration: true,
          buildTargetSchema: createV3Schema,
          backfillTables: <BackfillTable>[
            BackfillTable(
              name: 'items',
              orderByColumn: 'id',
              transform: (Map<String, Object?> row) => <String, Object?>{
                'id': row['id'],
                'profile_id': row['profile_id'],
                'name': row['title'],
                'status': 'open',
                'priority': 0,
                'created_at': row['created_at'],
              },
            ),
            const BackfillTable(name: 'item_events', orderByColumn: 'id'),
          ],
        ),
        MigrationPlan(
          sourceVersion: 2,
          targetVersion: 3,
          requiresShadowGeneration: false,
          applyInPlace: (MigrationConnection c) async {
            await c.execute(
              "ALTER TABLE items ADD COLUMN archived INTEGER NOT NULL "
              "DEFAULT 0",
            );
          },
        ),
      ]);

      final MigrationOutcome outcome = await migrator(
        registry: mixed,
      ).migrateToTarget(targetSchemaVersion: 3);
      expect(outcome.result, MigrationResult.activatedShadowGeneration);

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.generation.schemaVersion, 3);
      final MigrationConnection conn = await opener.open(
        layout.generationDirectory(p.directoryName),
        createIfMissing: false,
      );
      final int archived = await conn.scalarInt(
        'SELECT COUNT(*) AS n FROM items WHERE archived = 0',
      );
      final int recorded = await conn.scalarInt(
        'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
      );
      await conn.dispose();
      expect(archived, 8);
      expect(recorded, 3);
    },
  );
}

/// Verifier that always reports a failure, to drive the rollback branch.
final class _AlwaysFailVerifier extends MigrationVerifier {
  const _AlwaysFailVerifier();

  @override
  Future<VerificationReport> verify({
    required MigrationConnection source,
    required MigrationConnection shadow,
    required List<String> preservedTables,
  }) async => VerificationReport(<VerificationFailure>[
    const VerificationFailure('injected', 'forced failure'),
  ]);
}
