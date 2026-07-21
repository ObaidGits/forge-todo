import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart'
    show MigrationLayout;
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';
import 'package:forge/features/backup/infrastructure/staged_restore.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'backup_fixtures.dart';

/// Wave 12 release gate (task 12.6): **self-host restore** automation.
///
/// The operator self-host restore path is exercised in-repo by driving the
/// real FBC1 point-in-time export + staged generation restore (the same
/// machinery the security conformance harness in 9.2/9.9/9.10 + FBC1 restore
/// relies on), never a fork. An operator who owns their own PostgreSQL/object
/// backups (delivery.md §10) restores their local Forge store from an
/// authenticated FBC1 archive; this suite proves that local restore path:
///
/// * a full round-trip export → restore activates a verified generation at the
///   recorded `commit_seq`/schema version with the live store never mutated;
/// * a tampered archive is refused before any staging state is created.
///
/// The LIVE-database self-host parts (PostgreSQL/Supabase RLS, protocol, and
/// restore-responsibility SQL conformance) require a running instance and are
/// isolated as MANUAL/CI: `supabase/tests/0001_protocol_conformance.sql`,
/// `supabase/tests/0002_rls_surface.sql`, and the
/// `tool/probes/supabase_conformance` harness (enumerated by
/// `tool/release/staged_rollout.py self-host-restore`). They are not executed
/// here.
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-SELF-HOST-RESTORE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.6'),
  requirements: <RequirementId>[
    RequirementId('NFR-MAIN-004'),
    RequirementId('NFR-REL-002'),
  ],
);

const Fbc1KdfParameters _fastKdf = Fbc1KdfParameters(
  memoryKiB: 8 * 1024,
  iterations: 1,
);

void main() {
  late Directory root;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;
  late Fbc1Codec codec;
  const String liveDir = 'generation-live';
  final List<int> passphrase = 'operator restore passphrase'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-self-host-restore-');
    layout = MigrationLayout(baseDirectory: root.path);
    opener = Sqlite3MigrationConnectionOpener();
    pointer = ActiveGenerationPointer(pointerFile: layout.pointerFile);
    codec = Fbc1Codec(crypto: BackupTestCrypto());
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> seedLive({required int commitSeq}) async {
    final MigrationConnection c = await opener.open(
      layout.generationDirectory(liveDir),
      createIfMissing: true,
    );
    await seedBackupStore(
      c,
      commitSeq: commitSeq,
      generationId: 'gen-operator',
      items: 9,
      withFts: sqliteHasFts5(),
    );
    await c.dispose();
    await pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId('gen-operator'),
          schemaVersion: 1,
        ),
        directoryName: liveDir,
      ),
    );
  }

  Future<List<int>> operatorBackup({required int commitSeq}) async {
    await seedLive(commitSeq: commitSeq);
    final BackupExportResult result =
        await PointInTimeExporter(
          opener: opener,
          codec: codec,
          now: () => DateTime.utc(2026, 2, 2),
        ).export(
          generationDirectory: layout.generationDirectory(liveDir),
          passphrase: passphrase,
          kdf: _fastKdf,
        );
    return result.archive;
  }

  StagedRestoreService service() => StagedRestoreService(
    layout: layout,
    opener: opener,
    codec: codec,
    idGenerator: FakeIdGenerator.sequential(),
  );

  testWithEvidence(
    _evidence('ROUND-TRIP'),
    'an operator restores a self-hosted backup: export then staged restore '
    'activates a verified generation at the recorded commit_seq',
    () async {
      final List<int> archive = await operatorBackup(commitSeq: 42);

      final RestoreResult result = await service().restore(
        archive: archive,
        passphrase: passphrase,
      );

      expect(result.metadata.commitSeq, 42);
      expect(result.metadata.schemaVersion, 1);
      expect(result.activatedDirectoryName, isNot(liveDir));
      expect(result.priorDirectoryName, liveDir);

      // The pointer now names the restored, verified generation.
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, result.activatedDirectoryName);

      // The restored store carries the operator's committed data.
      final MigrationConnection restored = await opener.open(
        layout.generationDirectory(result.activatedDirectoryName),
        createIfMissing: false,
      );
      try {
        expect(await restored.countRows('items'), 9);
        final int maxSeq = await restored.scalarInt(
          'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
        );
        expect(maxSeq, 42);
      } finally {
        await restored.dispose();
      }
    },
  );

  testWithEvidence(
    _evidence('TAMPER-REJECTED'),
    'a tampered self-host archive is refused before any staging generation is '
    'created, leaving the live generation live',
    () async {
      final List<int> archive = await operatorBackup(commitSeq: 7);
      final List<int> tampered = List<int>.of(archive);
      tampered[tampered.length - 16] ^= 0x01;

      await expectLater(
        service().restore(archive: tampered, passphrase: passphrase),
        throwsA(
          isA<RestoreFailure>().having(
            (RestoreFailure e) => e.phase,
            'phase',
            'validate',
          ),
        ),
      );

      // The live generation is still the only one and still active.
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, liveDir);
      final List<String> dirs = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(dirs, <String>[liveDir]);
    },
  );
}
