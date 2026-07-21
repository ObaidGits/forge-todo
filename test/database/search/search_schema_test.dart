import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/schema/ownership_classification.dart';
import 'package:sqlite3/common.dart';

import '../schema/schema_test_database.dart';

/// Structural tests for the unified search schema: the concrete content tables,
/// their stable-row-id constraints and indexes, and the FTS5 external-content
/// virtual table.
///
/// **Validates: Requirements R-SEARCH-001, R-NOTE-004, R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;

  setUp(() {
    db = openSchemaDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  group('given the search schema when the database is created', () {
    test('then fts_rowids and search_documents tables exist', () async {
      final List<QueryRow> rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('fts_rowids', 'search_documents')",
          )
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      expect(names, containsAll(<String>['fts_rowids', 'search_documents']));
    });

    test('then the search_fts FTS5 virtual table exists', () async {
      final List<QueryRow> rows = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'search_fts'",
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['sql'] as String, contains('fts5'));
    });

    test('then FTS5 MATCH queries run against the external content', () async {
      final String profile = await insertProfile(db);
      await db.customStatement(
        'INSERT INTO fts_rowids '
        '(profile_id, entity_type, entity_id, fts_rowid, created_at_utc) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[profile, 'task', 't1', 1, 0],
      );
      await db.customStatement(
        'INSERT INTO search_documents '
        '(doc_rowid, profile_id, entity_type, entity_id, title, body, '
        'weight_version, title_weight, body_weight, source_revision, deleted, '
        'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
        <Object?>[1, profile, 'task', 't1', 'Buy milk', '', 1, 10.0, 1.0, 1, 0],
      );
      await db.customStatement(
        'INSERT INTO search_fts(rowid, title, body) VALUES (?, ?, ?)',
        <Object?>[1, 'Buy milk', ''],
      );
      final List<QueryRow> hits = await db
          .customSelect(
            "SELECT rowid FROM search_fts WHERE search_fts MATCH 'milk'",
          )
          .get();
      expect(hits, hasLength(1));
      expect(hits.single.data['rowid'], 1);
    });
  });

  group('given fts_rowids when enforcing stable-id invariants', () {
    Future<void> insertRowid(
      String profile,
      String type,
      String id,
      int rowid,
    ) => db.customStatement(
      'INSERT INTO fts_rowids '
      '(profile_id, entity_type, entity_id, fts_rowid, created_at_utc) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[profile, type, id, rowid, 0],
    );

    test('then a duplicate entity mapping is rejected', () async {
      final String profile = await insertProfile(db);
      await insertRowid(profile, 'task', 't1', 1);
      await expectLater(insertRowid(profile, 'task', 't1', 2), throwsSqlite);
    });

    test('then a duplicate row id is rejected', () async {
      final String profile = await insertProfile(db);
      await insertRowid(profile, 'task', 't1', 1);
      await expectLater(insertRowid(profile, 'task', 't2', 1), throwsSqlite);
    });

    test('then a non-positive row id is rejected', () async {
      final String profile = await insertProfile(db);
      await expectLater(insertRowid(profile, 'task', 't1', 0), throwsSqlite);
    });
  });

  group('given the ownership dictionary when classifying search tables', () {
    test('then both content tables are classified area-free', () {
      expect(ownershipClassFor('fts_rowids'), OwnershipClass.areaFree);
      expect(ownershipClassFor('search_documents'), OwnershipClass.areaFree);
    });
  });

  group('given search indexes when planning filtered queries', () {
    test('then the named search indexes are present', () async {
      final List<QueryRow> rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      for (final String expected in <String>[
        'ux_fts_rowids_entity',
        'ux_fts_rowids_rowid',
        'ux_search_documents_entity',
        'ux_search_documents_rowid',
        'ix_search_documents_type',
      ]) {
        expect(names, contains(expected), reason: 'missing index $expected');
      }
    });
  });
}
