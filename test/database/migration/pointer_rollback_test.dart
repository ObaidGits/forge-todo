import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';
import 'package:forge/features/backup/infrastructure/staged_restore.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import '../backup/backup_fixtures.dart';
import 'migration_fixtures.dart';

/// Wave 12 release gate (task 12.6): **pointer-rollback** automation.
///
/// A failed activation must roll the [ActiveGenerationPointer] back to the
/// prior generation, leaving it live and intact (NFR-REL-002, design §12). This
/// suite proves the rollback in BOTH machines that perform an atomic pointer
/// switch, reusing the existing staged-restore crash/rollback fault injector
/// rather than forking it:
///
/// * the [GenerationMigrator] shadow-activation path (post-activation verify
///   failure), and
/// * the [StagedRestoreService] restore-activation path (post-activation reopen
///   failure).
///
/// In each case the pointer is asserted to name the prior generation after the
/// failure, and a subsequent clean operation still succeeds — proving the
/// rollback left a clean, usable state.
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-POINTER-ROLLBACK-$suffix'),
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

/// Wraps a real opener and throws on the [failAt]-th open, driving a crash at a
/// specific activation phase deterministically (mirrors the staged-restore
/// crash/rollback fault injector).
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

void main() {
  late Directory root;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-pointer-rollback-');
    layout = MigrationLayout(baseDirectory: root.path);
    opener = Sqlite3MigrationConnectionOpener();
    pointer = ActiveGenerationPointer(pointerFile: layout.pointerFile);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  List<String> generationDirs() => root
      .listSync()
      .whereType<Directory>()
      .map((Directory d) => d.path.split('/').last)
      .where((String name) => name.startsWith('generation-'))
      .toList();

  group('migration shadow-activation rollback', () {
    const String sourceDirName = 'generation-source';

    Future<void> bootstrapSource({int items = 6}) async {
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

    testWithEvidence(
      _evidence('MIGRATION'),
      'a post-activation verification failure rolls the pointer back to the '
      'prior generation and discards the shadow',
      () async {
        await bootstrapSource();
        // A target schema omitting schema_metadata verifies as a shadow but
        // fails the post-switch schema-version confirmation, forcing the
        // pointer to roll back to the source generation.
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
                  'created_at': row['created_at'],
                },
              ),
            ],
          ),
        ]);

        final GenerationMigrator migrator = GenerationMigrator(
          layout: layout,
          opener: opener,
          registry: noMetadata,
          preflight: DiskSpacePreflight(FakeDiskSpaceProbe(8 << 30)),
          safetyBackup: SafetyBackup(now: () => DateTime.utc(2024)),
          verifier: const MigrationVerifier(),
          idGenerator: _SeqIds(),
        );

        await expectLater(
          migrator.migrateToTarget(targetSchemaVersion: 2),
          throwsA(
            isA<MigrationFailure>().having(
              (MigrationFailure e) => e.phase,
              'phase',
              'post_activation_verify',
            ),
          ),
        );

        // Pointer rolled back to the prior generation, shadow discarded.
        final ActiveGenerationRecord? p = await pointer.read();
        expect(p!.directoryName, sourceDirName);
        expect(p.generation.schemaVersion, 1);
        expect(generationDirs(), <String>[sourceDirName]);

        // The prior generation is still openable with its original data.
        final MigrationConnection conn = await opener.open(
          layout.generationDirectory(sourceDirName),
          createIfMissing: false,
        );
        expect(await conn.countRows('items'), 6);
        await conn.dispose();
      },
    );
  });

  group('restore-activation rollback (reused staged-restore machinery)', () {
    const String liveDir = 'generation-live';
    final List<int> passphrase = 'correct horse battery'.codeUnits;
    late Fbc1Codec codec;

    setUp(() {
      codec = Fbc1Codec(crypto: BackupTestCrypto());
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
        items: 5,
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
      final BackupExportResult result =
          await PointInTimeExporter(
            opener: opener,
            codec: codec,
            now: () => DateTime.utc(2026),
          ).export(
            generationDirectory: layout.generationDirectory(liveDir),
            passphrase: passphrase,
            kdf: const Fbc1KdfParameters(memoryKiB: 8 * 1024, iterations: 1),
          );
      return result.archive;
    }

    testWithEvidence(
      _evidence('RESTORE'),
      'a post-activation reopen failure rolls the pointer back to the live '
      'generation and a clean retry then succeeds',
      () async {
        await seedLive(commitSeq: 21);
        final List<int> archive = await exportLive();

        // Fail the second open (the post-activation reopen) to force rollback
        // after the pointer already switched once.
        final StagedRestoreService faulty = StagedRestoreService(
          layout: layout,
          opener: _FailOnNthOpen(opener, failAt: 2),
          codec: codec,
          idGenerator: FakeIdGenerator.sequential(),
        );
        await expectLater(
          faulty.restore(archive: archive, passphrase: passphrase),
          throwsA(
            isA<RestoreFailure>().having(
              (RestoreFailure e) => e.phase,
              'phase',
              'post_activation_verify',
            ),
          ),
        );

        // The pointer rolled back to the live generation.
        final ActiveGenerationRecord? afterFail = await pointer.read();
        expect(afterFail!.directoryName, liveDir);

        // A clean retry activates a new verified generation, proving the
        // rollback left a restorable state.
        final StagedRestoreService clean = StagedRestoreService(
          layout: layout,
          opener: opener,
          codec: codec,
          idGenerator: FakeIdGenerator.sequential(),
        );
        final RestoreResult result = await clean.restore(
          archive: archive,
          passphrase: passphrase,
        );
        expect(result.activatedDirectoryName, isNot(liveDir));
        expect(result.priorDirectoryName, liveDir);
        final ActiveGenerationRecord? afterOk = await pointer.read();
        expect(afterOk!.directoryName, result.activatedDirectoryName);
      },
    );
  });
}
