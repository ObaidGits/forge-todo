import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';

import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-BACKUP-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

void main() {
  late Directory root;
  late Directory sourceDir;
  late Directory backupRoot;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-backup-');
    sourceDir = Directory('${root.path}/generation-source')
      ..createSync(recursive: true);
    backupRoot = Directory('${root.path}/backups');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  SafetyBackup backup() => SafetyBackup(now: () => DateTime.utc(2024, 1, 2, 3));

  testWithEvidence(
    _evidence('001'),
    'a byte-identical old-version copy of every store file is produced',
    () async {
      await File(
        '${sourceDir.path}/store.sqlite',
      ).writeAsBytes(List<int>.generate(2048, (int i) => i % 256));
      await File(
        '${sourceDir.path}/store.sqlite-wal',
      ).writeAsBytes(<int>[1, 2, 3, 4]);

      final SafetyBackupRecord record = await backup().create(
        sourceGenerationDir: sourceDir,
        backupRoot: backupRoot,
        sourceSchemaVersion: 3,
        label: 'to-v4',
      );

      expect(record.schemaVersion, 3);
      expect(
        record.fileNames,
        containsAll(<String>['store.sqlite', 'store.sqlite-wal']),
      );
      final File copied = File('${record.directoryPath}/store.sqlite');
      expect(
        await copied.readAsBytes(),
        List<int>.generate(2048, (int i) => i % 256),
      );
      expect(record.totalBytes, 2048 + 4);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'a manifest sentinel is written only after every file is copied',
    () async {
      await File('${sourceDir.path}/store.sqlite').writeAsBytes(<int>[9, 9, 9]);
      final SafetyBackupRecord record = await backup().create(
        sourceGenerationDir: sourceDir,
        backupRoot: backupRoot,
        sourceSchemaVersion: 1,
        label: 'to-v2',
      );
      final File manifest = File(
        '${record.directoryPath}/backup_manifest.json',
      );
      expect(manifest.existsSync(), isTrue);
      final Map<String, Object?> json =
          jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
      expect(json['schema_version'], 1);
      expect(json['file_names'], contains('store.sqlite'));
    },
  );

  testWithEvidence(
    _evidence('003'),
    'a source with no store files is rejected rather than a silent no-op',
    () async {
      await expectLater(
        backup().create(
          sourceGenerationDir: sourceDir,
          backupRoot: backupRoot,
          sourceSchemaVersion: 1,
          label: 'empty',
        ),
        throwsA(isA<SafetyBackupException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a missing source generation directory is rejected',
    () async {
      await sourceDir.delete(recursive: true);
      await expectLater(
        backup().create(
          sourceGenerationDir: sourceDir,
          backupRoot: backupRoot,
          sourceSchemaVersion: 1,
          label: 'gone',
        ),
        throwsA(isA<SafetyBackupException>()),
      );
    },
  );
}
