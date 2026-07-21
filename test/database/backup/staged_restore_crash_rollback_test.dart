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
  evidenceId: EvidenceId('TEST-BACKUP-RESTORE-CRASH-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.8'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-003'),
    RequirementId('R-BACKUP-004'),
    RequirementId('NFR-REL-002'),
  ],
);

const Fbc1KdfParameters _fastKdf = Fbc1KdfParameters(
  memoryKiB: 8 * 1024,
  iterations: 1,
);

/// Wave 9 risk-gate recovery-rollback depth (task 10.8): a failed or aborted
/// staged generation restore rolls back leaving the *prior* generation live and
/// byte-for-byte intact, with no partial staging generation left behind — a
/// crash injected at each restore phase (R-BACKUP-003, R-BACKUP-004,
/// NFR-REL-002). This builds on 10.6's happy/tampered cases by asserting the
/// live store bytes are unchanged and no orphan generation directory survives
/// after a crash at validate, staging verification, and post-activation verify.
void main() {
  late Directory root;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;
  late Fbc1Codec codec;
  const String liveDir = 'generation-live';
  final List<int> passphrase = 'correct horse battery'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-restore-crash-');
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
      items: 6,
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

  Map<String, List<int>> snapshotLive() {
    final Directory dir = Directory(layout.generationDirectory(liveDir));
    return <String, List<int>>{
      for (final FileSystemEntity e in dir.listSync())
        if (e is File) e.path.split('/').last: e.readAsBytesSync(),
    };
  }

  List<String> generationDirs() => root
      .listSync()
      .whereType<Directory>()
      .map((Directory d) => d.path.split('/').last)
      .where((String name) => name.startsWith('generation-'))
      .toList();

  Future<void> expectLiveIntact(Map<String, List<int>> before) async {
    // The pointer still names the live generation.
    final ActiveGenerationRecord? p = await pointer.read();
    expect(p!.directoryName, liveDir);
    expect(p.generation.schemaVersion, 1);
    // Only the live generation directory exists — no partial staging left.
    expect(generationDirs(), <String>[liveDir]);
    // Every live store byte is unchanged.
    final Map<String, List<int>> after = snapshotLive();
    expect(after.keys.toSet(), before.keys.toSet());
    for (final MapEntry<String, List<int>> entry in before.entries) {
      expect(after[entry.key], entry.value, reason: entry.key);
    }
  }

  testWithEvidence(
    _evidence('VALIDATE-PHASE'),
    'a crash while validating a tampered archive leaves the prior generation '
    'live and byte-for-byte intact',
    () async {
      await seedLive(commitSeq: 11);
      final Map<String, List<int>> before = snapshotLive();
      final List<int> archive = await exportLive();
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
      await expectLiveIntact(before);
    },
  );

  testWithEvidence(
    _evidence('VERIFY-STAGING-PHASE'),
    'a crash while verifying the staged generation rolls back before '
    'activation, leaving the prior generation live and intact',
    () async {
      await seedLive(commitSeq: 12);
      final Map<String, List<int>> before = snapshotLive();
      final List<int> archive = await exportLive();

      // Fail the first open — the staged-store verification — to abort before
      // the atomic pointer switch.
      final _FailOnNthOpen faulty = _FailOnNthOpen(opener, failAt: 1);
      await expectLater(
        service(
          withOpener: faulty,
        ).restore(archive: archive, passphrase: passphrase),
        throwsA(isA<RestoreFailure>()),
      );
      await expectLiveIntact(before);
    },
  );

  testWithEvidence(
    _evidence('POST-ACTIVATION-PHASE'),
    'a crash during post-activation verification rolls the pointer back to the '
    'prior generation and discards the staging generation',
    () async {
      await seedLive(commitSeq: 13);
      final Map<String, List<int>> before = snapshotLive();
      final List<int> archive = await exportLive();

      // Fail the second open — the post-activation reopen — to force rollback
      // after the pointer has already switched once.
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
      await expectLiveIntact(before);
    },
  );

  testWithEvidence(
    _evidence('SUCCESS-AFTER-ABORTED'),
    'a normal restore still succeeds after an earlier aborted attempt, proving '
    'the rollback left the store in a clean, restorable state',
    () async {
      await seedLive(commitSeq: 14);
      final List<int> archive = await exportLive();

      // First attempt aborts at post-activation and rolls back.
      await expectLater(
        service(
          withOpener: _FailOnNthOpen(opener, failAt: 2),
        ).restore(archive: archive, passphrase: passphrase),
        throwsA(isA<RestoreFailure>()),
      );

      // A clean retry activates a new verified generation.
      final RestoreResult result = await service().restore(
        archive: archive,
        passphrase: passphrase,
      );
      expect(result.activatedDirectoryName, isNot(liveDir));
      expect(result.metadata.commitSeq, 14);
      final ActiveGenerationRecord? p = await pointer.read();
      expect(p!.directoryName, result.activatedDirectoryName);
    },
  );
}

/// Wraps a real opener and throws on the [failAt]-th open, to drive a crash at a
/// specific restore phase deterministically.
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
