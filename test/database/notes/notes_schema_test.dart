import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/common.dart';

import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Real schema / constraint / index tests for the notes tables.
///
/// **Validates: Requirements R-NOTE-001, R-NOTE-002, R-NOTE-005, R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;
  late String profile;

  setUp(() async {
    db = openSchemaDatabase();
    profile = await insertProfile(db);
    await insertLifeArea(db, profile);
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  Future<void> insertNote(
    String id, {
    String areaId = 'area-1',
    String title = 'Note',
    String normalizedTitle = 'note',
    String body = 'body',
    int pinned = 0,
    String rank = 'm',
    int revision = 1,
  }) => db.customStatement(
    'INSERT INTO notes '
    '(id, profile_id, life_area_id, title, normalized_title, body, '
    'content_hash, pinned, rank, revision, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      profile,
      areaId,
      title,
      normalizedTitle,
      body,
      'hash',
      pinned,
      rank,
      revision,
      0,
      0,
    ],
  );

  group('given the notes area foreign key (R-GEN-002)', () {
    test('then a note in an unknown area is rejected', () async {
      await expectLater(insertNote('n1', areaId: 'ghost'), throwsSqlite);
    });

    test('then a note in a valid area is accepted', () async {
      await insertNote('n1');
      expect(await _count(db, 'notes'), 1);
    });

    test('then revision must be >= 1', () async {
      await expectLater(insertNote('n1', revision: 0), throwsSqlite);
    });
  });

  group('given note_drafts (R-NOTE-005)', () {
    test('then a draft requires an existing note', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO note_drafts '
          '(profile_id, note_id, base_revision, encrypted_body, '
          'recovery_status, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[profile, 'ghost', 1, 'enc', 'active', 0, 0],
        ),
        throwsSqlite,
      );
    });

    test('then an unknown recovery_status is rejected', () async {
      await insertNote('n1');
      await expectLater(
        db.customStatement(
          'INSERT INTO note_drafts '
          '(profile_id, note_id, base_revision, encrypted_body, '
          'recovery_status, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[profile, 'n1', 1, 'enc', 'bogus', 0, 0],
        ),
        throwsSqlite,
      );
    });

    test('then one current draft per note is enforced by the PK', () async {
      await insertNote('n1');
      Future<void> draft() => db.customStatement(
        'INSERT INTO note_drafts '
        '(profile_id, note_id, base_revision, encrypted_body, '
        'recovery_status, created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        <Object?>[profile, 'n1', 1, 'enc', 'active', 0, 0],
      );
      await draft();
      await expectLater(draft(), throwsSqlite);
    });
  });

  group('given note_links (R-NOTE-003)', () {
    test('then a link requires an existing source note', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO note_links '
          '(id, profile_id, source_note_id, target_title, normalized_target, '
          'label, source_start, source_end, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>['l1', profile, 'ghost', 'X', 'x', 'X', 0, 5, 0],
        ),
        throwsSqlite,
      );
    });

    test('then two links cannot share one source position', () async {
      await insertNote('n1');
      Future<void> link(String id) => db.customStatement(
        'INSERT INTO note_links '
        '(id, profile_id, source_note_id, target_title, normalized_target, '
        'label, source_start, source_end, created_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[id, profile, 'n1', 'X', 'x', 'X', 3, 8, 0],
      );
      await link('l1');
      await expectLater(link('l2'), throwsSqlite);
    });
  });

  group('given measured indexes', () {
    test('then every named note index exists', () async {
      final List<QueryRow> rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      for (final String expected in <String>[
        'ux_notes_profile_id',
        'ux_notes_area_id',
        'idx_notes_pinned_updated',
        'ix_notes_hash',
        'ix_notes_norm_title',
        'ux_note_links_position',
        'ix_note_links_backlink',
      ]) {
        expect(names, contains(expected), reason: 'missing $expected');
      }
    });
  });
}

Future<int> _count(ForgeSchemaDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table')
      .get();
  return rows.single.data['n'] as int;
}
