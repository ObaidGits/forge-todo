import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-CONNECTION-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

void main() {
  late Sqlite3MigrationConnection conn;

  setUp(() async {
    conn = Sqlite3MigrationConnection(sqlite3.openInMemory());
    await conn.execute('CREATE TABLE t (id TEXT PRIMARY KEY)');
    await conn.execute('CREATE TABLE u (id TEXT PRIMARY KEY)');
    await conn.execute("INSERT INTO t VALUES ('a'), ('b'), ('c')");
  });

  tearDown(() async {
    await conn.dispose();
  });

  testWithEvidence(
    _evidence('001'),
    'countRows and scalarInt read integer aggregates',
    () async {
      expect(await conn.countRows('t'), 3);
      expect(await conn.scalarInt('SELECT 41 + 1 AS n'), 42);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'scalarInt returns zero for an empty result set',
    () async {
      expect(await conn.scalarInt("SELECT id FROM t WHERE id = 'missing'"), 0);
    },
  );

  testWithEvidence(
    _evidence('003'),
    'scalarInt rejects a non-integer scalar',
    () async {
      await expectLater(
        conn.scalarInt("SELECT 'text' AS n"),
        throwsA(isA<MigrationConnectionException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('004'),
    'userTables lists user tables and excludes SQLite internals',
    () async {
      final List<String> tables = await conn.userTables();
      expect(tables, containsAll(<String>['t', 'u']));
      expect(
        tables.every((String name) => !name.startsWith('sqlite_')),
        isTrue,
      );
    },
  );

  testWithEvidence(
    _evidence('005'),
    'a transaction rolls back its writes when the body throws',
    () async {
      await expectLater(
        conn.transaction(() async {
          await conn.execute("INSERT INTO t VALUES ('d')");
          throw const FormatException('boom');
        }),
        throwsA(isA<FormatException>()),
      );
      expect(await conn.countRows('t'), 3, reason: 'insert rolled back');
    },
  );

  testWithEvidence(
    _evidence('006'),
    'MigrationConnectionException carries a descriptive message',
    () async {
      const MigrationConnectionException error = MigrationConnectionException(
        'nope',
      );
      expect(error.toString(), contains('nope'));
    },
  );
}
