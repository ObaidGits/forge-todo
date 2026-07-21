import 'dart:io';
import 'dart:typed_data';

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
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'backup_fixtures.dart';

/// Wave 2 hardening — concurrent-backup safety and the wrong-passphrase restore
/// path.
///
/// A point-in-time export must produce a transactionally consistent snapshot
/// even while other connections write to the same store: the archive is a valid
/// point-in-time image (never a torn/partial transaction), and the live store
/// keeps every concurrent write intact (`R-BACKUP-001`, `NFR-REL-002`). A
/// restore under the wrong passphrase must be rejected before any staging
/// generation is built, leaving the live pointer untouched (`NFR-REL-004`).
EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['NFR-REL-002'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-CONCURRENT-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.11'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

const Fbc1KdfParameters _fastKdf = Fbc1KdfParameters(
  memoryKiB: 8 * 1024,
  iterations: 1,
);

/// Captures the decoded plaintext bytes of a single file from an FBC1 archive.
final class _SingleFileSink implements Fbc1FileSink {
  _SingleFileSink(this.wanted);

  final String wanted;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool _capturing = false;
  Uint8List? bytes;

  @override
  Future<void> begin(String path, int fileSize) async {
    _capturing = path == wanted;
  }

  @override
  Future<void> chunk(String path, Uint8List data) async {
    if (_capturing) {
      _builder.add(data);
    }
  }

  @override
  Future<void> end(String path) async {
    if (_capturing) {
      bytes = _builder.takeBytes();
      _capturing = false;
    }
  }
}

/// Facts read from a decoded snapshot store, used to prove point-in-time
/// consistency.
final class _SnapshotFacts {
  const _SnapshotFacts({
    required this.integrityOk,
    required this.foreignKeysOk,
    required this.maxCommitSeq,
    required this.contiguousCommits,
    required this.commitCount,
    required this.itemCount,
    required this.eventCount,
  });

  final bool integrityOk;
  final bool foreignKeysOk;
  final int maxCommitSeq;
  final bool contiguousCommits;
  final int commitCount;
  final int itemCount;
  final int eventCount;

  @override
  String toString() =>
      '_SnapshotFacts(integrity=$integrityOk, fk=$foreignKeysOk, '
      'max=$maxCommitSeq, contiguous=$contiguousCommits, commits=$commitCount, '
      'items=$itemCount, events=$eventCount)';
}

void main() {
  late Directory root;
  late Sqlite3MigrationConnectionOpener opener;
  late Fbc1Codec codec;
  late PointInTimeExporter exporter;
  const String liveDir = 'generation-live';
  final List<int> passphrase = 'correct horse battery staple'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-concurrent-backup-');
    opener = Sqlite3MigrationConnectionOpener();
    codec = Fbc1Codec(crypto: BackupTestCrypto());
    exporter = PointInTimeExporter(
      opener: opener,
      codec: codec,
      now: () => DateTime.utc(2026),
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  String storePath() => '${root.path}/$liveDir/store.sqlite';

  Future<void> seedLive({required int commitSeq, required int items}) async {
    final MigrationConnection c = await opener.open(
      '${root.path}/$liveDir',
      createIfMissing: true,
    );
    // A write-ahead log lets readers take a consistent snapshot while a writer
    // is active, which is the realistic backup-under-writes configuration.
    await c.execute('PRAGMA journal_mode=WAL');
    await seedBackupStore(
      c,
      commitSeq: commitSeq,
      generationId: 'gen-source',
      items: items,
      withFts: sqliteHasFts5(),
    );
    await c.dispose();
  }

  /// Appends one coupled (commit_log, items, item_events) triple for [seq] on a
  /// caller-owned connection so a consistent snapshot always has equal counts.
  void appendCoupledCommit(Database db, int seq) {
    db.execute('BEGIN IMMEDIATE');
    db.execute(
      'INSERT INTO commit_log (profile_id, commit_seq, command_id, '
      'committed_at) VALUES (?, ?, ?, ?)',
      <Object?>['profile-1', seq, 'cmd-$seq', seq],
    );
    final String id = 'item-${seq.toString().padLeft(6, '0')}';
    db.execute(
      'INSERT INTO items (id, profile_id, title, created_at) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[id, 'profile-1', 'Title $seq', seq],
    );
    db.execute(
      'INSERT INTO item_events (id, item_id, kind, at) VALUES (?, ?, ?, ?)',
      <Object?>['evt-${seq.toString().padLeft(6, '0')}', id, 'created', seq],
    );
    db.execute('COMMIT');
  }

  Future<_SnapshotFacts> readSnapshot(List<int> archive) async {
    final _SingleFileSink sink = _SingleFileSink('store.sqlite');
    await codec.restore(passphrase: passphrase, archive: archive, sink: sink);
    final File snapshot = File('${root.path}/decoded-snapshot.sqlite');
    await snapshot.writeAsBytes(sink.bytes!, flush: true);
    final Database db = sqlite3.open(snapshot.path);
    try {
      final ResultSet integrity = db.select('PRAGMA integrity_check');
      final bool integrityOk =
          integrity.isNotEmpty &&
          integrity.first.values.first.toString() == 'ok';
      final ResultSet fk = db.select('PRAGMA foreign_key_check');
      final int maxSeq =
          db
                  .select(
                    'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
                  )
                  .first
                  .values
                  .first
              as int;
      final int distinct =
          db
                  .select(
                    'SELECT COUNT(DISTINCT commit_seq) AS v FROM commit_log',
                  )
                  .first
                  .values
                  .first
              as int;
      final int commitCount =
          db.select('SELECT COUNT(*) AS v FROM commit_log').first.values.first
              as int;
      final int itemCount =
          db.select('SELECT COUNT(*) AS v FROM items').first.values.first
              as int;
      final int eventCount =
          db.select('SELECT COUNT(*) AS v FROM item_events').first.values.first
              as int;
      return _SnapshotFacts(
        integrityOk: integrityOk,
        foreignKeysOk: fk.isEmpty,
        maxCommitSeq: maxSeq,
        contiguousCommits: distinct == maxSeq && commitCount == maxSeq,
        commitCount: commitCount,
        itemCount: itemCount,
        eventCount: eventCount,
      );
    } finally {
      db.close();
      if (snapshot.existsSync()) {
        snapshot.deleteSync();
      }
    }
  }

  group('concurrent-write point-in-time snapshot', () {
    testWithEvidence(
      _evidence('001', requirements: <String>['NFR-REL-002', 'R-BACKUP-001']),
      'an export taken while writes are committing produces a consistent '
      'point-in-time snapshot and never loses the concurrent writes',
      () async {
        await seedLive(commitSeq: 10, items: 10);
        final Database writer = sqlite3.open(storePath());
        writer.execute('PRAGMA busy_timeout=10000');

        try {
          List<int>? archive;
          // Interleave the export with a stream of committing writers on a
          // separate connection. The futures cooperate through await points so
          // the snapshot may be taken at any commit boundary.
          final Future<void> exportFuture = () async {
            final BackupExportResult result = await exporter.export(
              generationDirectory: '${root.path}/$liveDir',
              passphrase: passphrase,
              kdf: _fastKdf,
            );
            archive = result.archive;
          }();
          final Future<void> writeFuture = () async {
            for (int seq = 11; seq <= 40; seq += 1) {
              await Future<void>.delayed(Duration.zero);
              appendCoupledCommit(writer, seq);
            }
          }();
          await Future.wait<void>(<Future<void>>[exportFuture, writeFuture]);

          final _SnapshotFacts facts = await readSnapshot(archive!);
          // The snapshot is a valid, internally consistent point-in-time: no
          // torn transaction is ever captured.
          expect(facts.integrityOk, isTrue, reason: '$facts');
          expect(facts.foreignKeysOk, isTrue, reason: '$facts');
          expect(facts.contiguousCommits, isTrue, reason: '$facts');
          expect(
            facts.maxCommitSeq,
            inInclusiveRange(10, 40),
            reason: '$facts',
          );
          // Counts are coupled per commit, so a coherent snapshot has equal
          // commit/item/event counts matching its own MAX(commit_seq).
          expect(facts.commitCount, facts.maxCommitSeq, reason: '$facts');
          expect(facts.itemCount, facts.maxCommitSeq, reason: '$facts');
          expect(facts.eventCount, facts.maxCommitSeq, reason: '$facts');
        } finally {
          writer.close();
        }

        // The live store retains every concurrent write and stays coherent.
        final MigrationConnection live = await opener.open(
          '${root.path}/$liveDir',
          createIfMissing: false,
        );
        try {
          final List<Map<String, Object?>> integrity = await live.select(
            'PRAGMA integrity_check',
          );
          expect(integrity.first.values.first.toString(), 'ok');
          expect(
            await live.scalarInt(
              'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
            ),
            40,
          );
          expect(await live.countRows('items'), 40);
          expect(await live.countRows('item_events'), 40);
        } finally {
          await live.dispose();
        }
      },
    );

    testWithEvidence(
      _evidence('002', requirements: <String>['NFR-REL-002', 'R-BACKUP-001']),
      'an uncommitted concurrent write is invisible to the point-in-time '
      'snapshot',
      () async {
        await seedLive(commitSeq: 15, items: 15);
        final Database writer = sqlite3.open(storePath());
        writer.execute('PRAGMA busy_timeout=10000');
        // Begin a write transaction and insert, but do NOT commit.
        writer.execute('BEGIN IMMEDIATE');
        writer.execute(
          'INSERT INTO commit_log (profile_id, commit_seq, command_id, '
          'committed_at) VALUES (?, ?, ?, ?)',
          <Object?>['profile-1', 16, 'cmd-16', 16],
        );

        try {
          final BackupExportResult result = await exporter.export(
            generationDirectory: '${root.path}/$liveDir',
            passphrase: passphrase,
            kdf: _fastKdf,
          );
          final _SnapshotFacts facts = await readSnapshot(result.archive);
          // The uncommitted commit 16 must not appear in the snapshot.
          expect(facts.integrityOk, isTrue, reason: '$facts');
          expect(facts.maxCommitSeq, 15, reason: '$facts');
          expect(facts.contiguousCommits, isTrue, reason: '$facts');
        } finally {
          writer.execute('ROLLBACK');
          writer.close();
        }
      },
    );
  });

  group('wrong-passphrase restore', () {
    testWithEvidence(
      _evidence('003', requirements: <String>['NFR-REL-004', 'R-BACKUP-002']),
      'a restore under the wrong passphrase is rejected at validation and '
      'leaves the live generation active',
      () async {
        await seedLive(commitSeq: 6, items: 6);
        final MigrationLayout layout = MigrationLayout(
          baseDirectory: root.path,
        );
        final ActiveGenerationPointer pointer = ActiveGenerationPointer(
          pointerFile: layout.pointerFile,
        );
        await pointer.switchTo(
          ActiveGenerationRecord(
            generation: DatabaseGeneration(
              id: GenerationId('gen-source'),
              schemaVersion: 1,
            ),
            directoryName: liveDir,
          ),
        );
        final BackupExportResult result = await exporter.export(
          generationDirectory: layout.generationDirectory(liveDir),
          passphrase: passphrase,
          kdf: _fastKdf,
        );

        final StagedRestoreService restore = StagedRestoreService(
          layout: layout,
          opener: opener,
          codec: codec,
          idGenerator: FakeIdGenerator.sequential(),
        );

        await expectLater(
          restore.restore(
            archive: result.archive,
            passphrase: 'a completely different passphrase'.codeUnits,
          ),
          throwsA(
            isA<RestoreFailure>().having(
              (RestoreFailure e) => e.phase,
              'phase',
              'validate',
            ),
          ),
        );

        // The live pointer and generation are untouched: no staging generation
        // was activated under a failed authentication.
        final ActiveGenerationRecord? after = await pointer.read();
        expect(after!.directoryName, liveDir);
        final List<String> generations = root
            .listSync()
            .whereType<Directory>()
            .map((Directory d) => d.path.split('/').last)
            .where((String name) => name.startsWith('generation-'))
            .toList();
        expect(generations, <String>[liveDir]);
      },
    );
  });
}
