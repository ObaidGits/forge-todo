import 'dart:convert';
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

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-RESTORE-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.6'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-002'),
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
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;
  late Fbc1Codec codec;
  const String liveDir = 'generation-live';
  final List<int> passphrase = 'correct horse battery'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-restore-');
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

  Future<void> seedLive({required int commitSeq, int items = 5}) async {
    final MigrationConnection c = await opener.open(
      layout.generationDirectory(liveDir),
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

  Future<List<int>> exportLive() async {
    final PointInTimeExporter exporter = PointInTimeExporter(
      opener: opener,
      codec: codec,
      now: () => DateTime.utc(2026),
    );
    final BackupExportResult result = await exporter.export(
      generationDirectory: layout.generationDirectory(liveDir),
      passphrase: passphrase,
      kdf: _fastKdf,
    );
    return result.archive;
  }

  StagedRestoreService service({MigrationConnectionOpener? withOpener}) =>
      StagedRestoreService(
        layout: layout,
        opener: withOpener ?? opener,
        codec: codec,
        idGenerator: FakeIdGenerator.sequential(),
      );

  Map<String, List<int>> snapshotDir(String name) {
    final Directory dir = Directory(layout.generationDirectory(name));
    return <String, List<int>>{
      for (final FileSystemEntity e in dir.listSync())
        if (e is File) e.path.split('/').last: e.readAsBytesSync(),
    };
  }

  testWithEvidence(
    _evidence('001'),
    'a round trip export then restore activates a new verified generation '
    'holding the snapshot data',
    () async {
      await seedLive(commitSeq: 10, items: 5);
      final List<int> archive = await exportLive();

      final RestoreResult result = await service().restore(
        archive: archive,
        passphrase: passphrase,
      );

      expect(result.activatedDirectoryName, isNot(liveDir));
      expect(result.priorDirectoryName, liveDir);
      expect(result.metadata.commitSeq, 10);

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, result.activatedDirectoryName);
      expect(p.generation.schemaVersion, 1);

      final MigrationConnection restored = await opener.open(
        layout.generationDirectory(result.activatedDirectoryName),
        createIfMissing: false,
      );
      final int items = await restored.countRows('items');
      final int maxSeq = await restored.scalarInt(
        'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
      );
      await restored.dispose();
      expect(items, 5);
      expect(maxSeq, 10);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'restore targets staging and never mutates the live generation',
    () async {
      await seedLive(commitSeq: 4);
      final Map<String, List<int>> liveBefore = snapshotDir(liveDir);
      final List<int> archive = await exportLive();

      await service().restore(archive: archive, passphrase: passphrase);

      final Map<String, List<int>> liveAfter = snapshotDir(liveDir);
      expect(liveAfter.keys.toSet(), liveBefore.keys.toSet());
      for (final MapEntry<String, List<int>> entry in liveBefore.entries) {
        expect(liveAfter[entry.key], entry.value, reason: entry.key);
      }
    },
  );

  testWithEvidence(
    _evidence('003'),
    'a tampered archive is rejected before any staging generation is built '
    'and leaves the live pointer unchanged',
    () async {
      await seedLive(commitSeq: 6);
      final List<int> archive = await exportLive();
      final List<int> tampered = List<int>.of(archive);
      tampered[tampered.length - 15] ^= 0x01;

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

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, liveDir);
      final List<String> generations = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(generations, <String>[liveDir]);
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a staged store whose schema disagrees with the manifest fails staging '
    'verification and leaves the live generation active',
    () async {
      await seedLive(commitSeq: 5);
      // Build the real store bytes then wrap them with metadata claiming a
      // different schema version, so staging verification must reject it.
      final File liveStore = File(
        '${layout.generationDirectory(liveDir)}/store.sqlite',
      );
      final List<int> storeBytes = await liveStore.readAsBytes();
      final BackupMetadata badMeta = BackupMetadata(
        commitSeq: 5,
        schemaVersion: 999,
        generationId: 'gen-source',
        createdAtUtcMicros: 0,
      );
      final List<int> archive = codec.encode(
        passphrase: passphrase,
        salt: codec.crypto.randomBytes(16),
        kdf: _fastKdf,
        files: <Fbc1File>[
          Fbc1File(
            'backup_meta.json',
            utf8.encode(jsonEncode(badMeta.toJson())),
          ),
          Fbc1File('store.sqlite', storeBytes),
        ],
      );

      await expectLater(
        service().restore(archive: archive, passphrase: passphrase),
        throwsA(
          isA<RestoreFailure>().having(
            (RestoreFailure e) => e.phase,
            'phase',
            'verify_staging',
          ),
        ),
      );

      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, liveDir);
      final List<String> generations = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(generations, <String>[liveDir]);
    },
  );

  testWithEvidence(
    _evidence('005'),
    'a post-activation verification failure restores the prior pointer and '
    'discards the staging generation (rollback)',
    () async {
      await seedLive(commitSeq: 8);
      final List<int> archive = await exportLive();

      // Fail the second open (the post-activation reopen) to force rollback.
      final _FailOnNthOpen faulty = _FailOnNthOpen(opener, failAt: 2);

      await expectLater(
        service(
          withOpener: faulty,
        ).restore(archive: archive, passphrase: passphrase),
        throwsA(
          isA<RestoreFailure>().having(
            (RestoreFailure e) => e.phase,
            'phase',
            'post_activation_verify',
          ),
        ),
      );

      // Rolled back: the live generation is active again and no staging
      // generation remains.
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, liveDir);
      expect(p.generation.schemaVersion, 1);
      final List<String> generations = root
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split('/').last)
          .where((String name) => name.startsWith('generation-'))
          .toList();
      expect(generations, <String>[liveDir]);
    },
  );

  testWithEvidence(
    _evidence('006'),
    'restore onto a fresh install with no prior generation activates cleanly',
    () async {
      // Seed a source, export it, then wipe the pointer to simulate a fresh
      // install performing a restore.
      await seedLive(commitSeq: 3);
      final List<int> archive = await exportLive();
      await layout.pointerFile.delete();

      final RestoreResult result = await service().restore(
        archive: archive,
        passphrase: passphrase,
      );
      expect(result.priorDirectoryName, isNull);
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, result.activatedDirectoryName);
    },
  );
}

/// Wraps a real opener and throws on the [failAt]-th open, to drive the
/// post-activation rollback branch deterministically.
final class _FailOnNthOpen implements MigrationConnectionOpener {
  _FailOnNthOpen(this._delegate, {required this.failAt});

  final MigrationConnectionOpener _delegate;
  final int failAt;
  int _opens = 0;

  @override
  Future<MigrationConnection> open(
    String generationDirectory, {
    required bool createIfMissing,
  }) async {
    _opens += 1;
    if (_opens == failAt) {
      throw const MigrationConnectionException('injected open failure');
    }
    return _delegate.open(
      generationDirectory,
      createIfMissing: createIfMissing,
    );
  }
}
