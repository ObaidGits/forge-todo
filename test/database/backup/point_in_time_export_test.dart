import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'backup_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-EXPORT-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.6'),
  requirements: <RequirementId>[RequirementId('R-BACKUP-001')],
);

void main() {
  late Directory root;
  late Sqlite3MigrationConnectionOpener opener;
  late PointInTimeExporter exporter;
  const String genDir = 'generation-source';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-export-');
    opener = Sqlite3MigrationConnectionOpener();
    exporter = PointInTimeExporter(
      opener: opener,
      codec: Fbc1Codec(crypto: BackupTestCrypto()),
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      // Fast, non-production KDF for tests.
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> seedSource({required int commitSeq, int items = 5}) async {
    final MigrationConnection c = await opener.open(
      '${root.path}/$genDir',
      createIfMissing: true,
    );
    await seedBackupStore(
      c,
      commitSeq: commitSeq,
      generationId: 'gen-source',
      items: items,
      withFts: sqliteHasFts5(),
    );
    await c.dispose();
  }

  testWithEvidence(
    _evidence('001'),
    'export captures the current commit_seq, schema version, and generation id',
    () async {
      await seedSource(commitSeq: 42);
      final BackupExportResult result = await exporter.export(
        generationDirectory: '${root.path}/$genDir',
        passphrase: 'pw'.codeUnits,
        kdf: const Fbc1KdfParameters(memoryKiB: 8 * 1024, iterations: 1),
      );
      expect(result.metadata.commitSeq, 42);
      expect(result.metadata.schemaVersion, 1);
      expect(result.metadata.generationId, 'gen-source');
      expect(result.metadata.excludesAttachments, isTrue);
      expect(result.fileCount, 2);
      expect(result.archive, isNotEmpty);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'the exported archive validates under bounded authenticated validation',
    () async {
      await seedSource(commitSeq: 7);
      final Fbc1Codec codec = Fbc1Codec(crypto: BackupTestCrypto());
      final PointInTimeExporter exporter2 = PointInTimeExporter(
        opener: opener,
        codec: codec,
        now: () => DateTime.utc(2026),
      );
      final BackupExportResult result = await exporter2.export(
        generationDirectory: '${root.path}/$genDir',
        passphrase: 'pw'.codeUnits,
        kdf: const Fbc1KdfParameters(memoryKiB: 8 * 1024, iterations: 1),
      );
      final Fbc1DecodeMetrics metrics = await codec.validate(
        passphrase: 'pw'.codeUnits,
        archive: result.archive,
      );
      expect(metrics.fileCount, 2);
      expect(metrics.plaintextBytes, result.plaintextBytes);
    },
  );

  testWithEvidence(
    _evidence('003'),
    'export reads the source only and never writes to the generation directory',
    () async {
      await seedSource(commitSeq: 3);
      final Directory dir = Directory('${root.path}/$genDir');
      final Map<String, int> before = <String, int>{
        for (final FileSystemEntity e in dir.listSync())
          if (e is File) e.path: e.lengthSync(),
      };
      await exporter.export(
        generationDirectory: '${root.path}/$genDir',
        passphrase: 'pw'.codeUnits,
        kdf: const Fbc1KdfParameters(memoryKiB: 8 * 1024, iterations: 1),
      );
      final Map<String, int> after = <String, int>{
        for (final FileSystemEntity e in dir.listSync())
          if (e is File) e.path: e.lengthSync(),
      };
      expect(after.keys.toSet(), before.keys.toSet());
      for (final MapEntry<String, int> entry in before.entries) {
        expect(after[entry.key], entry.value);
      }
    },
  );

  testWithEvidence(
    _evidence('004'),
    'export at commit_seq 0 succeeds for a freshly initialised store',
    () async {
      await seedSource(commitSeq: 0);
      final BackupExportResult result = await exporter.export(
        generationDirectory: '${root.path}/$genDir',
        passphrase: 'pw'.codeUnits,
        kdf: const Fbc1KdfParameters(memoryKiB: 8 * 1024, iterations: 1),
      );
      expect(result.metadata.commitSeq, 0);
    },
  );
}
