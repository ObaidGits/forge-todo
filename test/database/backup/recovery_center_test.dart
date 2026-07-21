import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart'
    show MigrationLayout;
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';
import 'package:forge/features/backup/infrastructure/recovery_center.dart';
import 'package:forge/features/backup/infrastructure/staged_restore.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'backup_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-RECOVERY-CENTER-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.6'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-003'),
    RequirementId('R-BACKUP-004'),
  ],
);

const Fbc1KdfParameters _fastKdf = Fbc1KdfParameters(
  memoryKiB: 8 * 1024,
  iterations: 1,
);

void main() {
  late Directory root;
  late Directory backupsDir;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;
  late Fbc1Codec codec;
  const String liveDir = 'generation-live';
  final List<int> passphrase = 'correct horse battery'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-recovery-center-');
    backupsDir = await Directory('${root.path}/backups').create();
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
      generationId: 'gen-source',
      items: 4,
      withFts: sqliteHasFts5(),
    );
    await c.dispose();
    await pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId('gen-source'),
          schemaVersion: 1,
        ),
        directoryName: liveDir,
      ),
    );
  }

  Future<File> writeArchive(String name, {required int commitSeq}) async {
    final PointInTimeExporter export = PointInTimeExporter(
      opener: opener,
      codec: codec,
      now: () => DateTime.utc(2026),
    );
    final BackupExportResult result = await export.export(
      generationDirectory: layout.generationDirectory(liveDir),
      passphrase: passphrase,
      kdf: _fastKdf,
    );
    final File file = File('${backupsDir.path}/$name');
    await file.writeAsBytes(result.archive);
    return file;
  }

  StagedRestoreService staged() => StagedRestoreService(
    layout: layout,
    opener: opener,
    codec: codec,
    idGenerator: FakeIdGenerator.sequential(),
  );

  RecoveryCenterService center() => RecoveryCenterService(
    stagedRestore: staged(),
    recoveryDirectories: <RecoveryDirectory>[
      RecoveryDirectory(
        path: backupsDir.path,
        source: RecoverySource.safetyBackup,
      ),
    ],
  );

  testWithEvidence(
    _evidence('LIST'),
    'the recovery center lists discovered archives as recovery points',
    () async {
      await seedLive(commitSeq: 7);
      await writeArchive('backup-a.fbc1', commitSeq: 7);
      await writeArchive('backup-b.fbc1', commitSeq: 7);
      // A non-archive file is ignored.
      await File('${backupsDir.path}/notes.txt').writeAsString('ignore me');

      final List<RecoveryPoint> points = await center().listRecoveryPoints();
      expect(points.length, 2);
      expect(
        points.every(
          (RecoveryPoint p) => p.source == RecoverySource.safetyBackup,
        ),
        isTrue,
      );
      expect(points.every((RecoveryPoint p) => p.sizeBytes > 0), isTrue);
    },
  );

  testWithEvidence(
    _evidence('RESTORE'),
    'restoring a recovery point drives staged restore and activates a new '
    'verified generation atomically',
    () async {
      await seedLive(commitSeq: 9);
      await writeArchive('backup.fbc1', commitSeq: 9);
      final List<RecoveryPoint> points = await center().listRecoveryPoints();

      final RecoveryRestoreOutcome outcome = await center().restore(
        point: points.single,
        passphrase: passphrase,
      );
      expect(outcome.recoveredCommitSeq, 9);
      expect(outcome.schemaVersion, 1);
      expect(outcome.rolledBack, isFalse);

      // The active pointer moved to a new generation, not the original live dir.
      final ActiveGenerationRecord? active = await pointer.read();
      expect(active!.directoryName, isNot(liveDir));
    },
  );

  testWithEvidence(
    _evidence('RESTORE-REJECTS-TAMPERED'),
    'a tampered archive fails without activating and the live generation stays',
    () async {
      await seedLive(commitSeq: 5);
      final File file = await writeArchive('backup.fbc1', commitSeq: 5);
      final List<int> bytes = await file.readAsBytes();
      bytes[bytes.length - 12] ^= 0x01;
      await file.writeAsBytes(bytes);

      final List<RecoveryPoint> points = await center().listRecoveryPoints();
      await expectLater(
        center().restore(point: points.single, passphrase: passphrase),
        throwsA(isA<RecoveryCenterException>()),
      );

      final ActiveGenerationRecord? active = await pointer.read();
      expect(active!.directoryName, liveDir);
    },
  );
}
