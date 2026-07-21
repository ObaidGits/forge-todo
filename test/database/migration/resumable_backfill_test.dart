import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/resumable_backfill.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-BACKFILL-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

Future<void> _createT(MigrationConnection c) =>
    c.execute('CREATE TABLE t (id TEXT NOT NULL PRIMARY KEY, v INTEGER)');

Future<void> _seed(MigrationConnection c, int rows) async {
  for (int i = 0; i < rows; i += 1) {
    await c.execute('INSERT INTO t (id, v) VALUES (?, ?)', <Object?>[
      'k-${i.toString().padLeft(6, '0')}',
      i,
    ]);
  }
}

void main() {
  late Sqlite3MigrationConnection source;
  late Sqlite3MigrationConnection shadow;

  setUp(() async {
    source = Sqlite3MigrationConnection(sqlite3.openInMemory());
    shadow = Sqlite3MigrationConnection(sqlite3.openInMemory());
    await _createT(source);
    await _createT(shadow);
  });

  tearDown(() async {
    await source.dispose();
    await shadow.dispose();
  });

  const BackfillTable table = BackfillTable(name: 't', orderByColumn: 'id');

  testWithEvidence(
    _evidence('001'),
    'a full bounded backfill copies every row across many batches',
    () async {
      await _seed(source, 10);
      const ResumableBackfill backfill = ResumableBackfill(batchSize: 3);
      final BackfillReport report = await backfill.run(
        source: source,
        shadow: shadow,
        tables: <BackfillTable>[table],
      );
      expect(report.rowsCopied, 10);
      expect(report.tablesCompleted, 1);
      expect(await shadow.countRows('t'), 10);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'a run interrupted after committed batches resumes from the cursor '
    'without duplicating or skipping rows',
    () async {
      await _seed(source, 10);
      const ResumableBackfill backfill = ResumableBackfill(batchSize: 3);
      // Simulate a prior interrupted run: four rows already durably copied and
      // the persisted cursor at the fourth id.
      await backfill.ensureProgressTable(shadow);
      for (int i = 0; i < 4; i += 1) {
        await shadow.execute('INSERT INTO t (id, v) VALUES (?, ?)', <Object?>[
          'k-${i.toString().padLeft(6, '0')}',
          i,
        ]);
      }
      await shadow.execute(
        'INSERT INTO "$kBackfillProgressTable" '
        '(table_name, last_key, rows_copied, done) VALUES (?, ?, ?, 0)',
        <Object?>['t', 'k-000003', 4],
      );

      final BackfillReport report = await backfill.run(
        source: source,
        shadow: shadow,
        tables: <BackfillTable>[table],
      );

      // Only the remaining six rows are copied this pass.
      expect(report.rowsCopied, 6);
      expect(await shadow.countRows('t'), 10);
      final int distinct = await shadow.scalarInt(
        'SELECT COUNT(DISTINCT id) AS n FROM t',
      );
      expect(distinct, 10, reason: 'no duplicates introduced');
    },
  );

  testWithEvidence(
    _evidence('003'),
    'an already-completed table is not recopied on a repeated run',
    () async {
      await _seed(source, 5);
      const ResumableBackfill backfill = ResumableBackfill(batchSize: 10);
      await backfill.run(
        source: source,
        shadow: shadow,
        tables: <BackfillTable>[table],
      );
      final BackfillReport second = await backfill.run(
        source: source,
        shadow: shadow,
        tables: <BackfillTable>[table],
      );
      expect(second.rowsCopied, 0, reason: 'table already marked done');
      expect(await shadow.countRows('t'), 5);
    },
  );

  testWithEvidence(
    _evidence('004'),
    'an empty source table completes cleanly and is marked done',
    () async {
      const ResumableBackfill backfill = ResumableBackfill(batchSize: 4);
      final BackfillReport report = await backfill.run(
        source: source,
        shadow: shadow,
        tables: <BackfillTable>[table],
      );
      expect(report.rowsCopied, 0);
      expect(report.tablesCompleted, 1);
      final int done = await shadow.scalarInt(
        'SELECT done FROM "$kBackfillProgressTable" WHERE table_name = \'t\'',
      );
      expect(done, 1);
    },
  );
}
