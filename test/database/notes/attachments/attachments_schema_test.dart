import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/common.dart';

import '../../schema/schema_test_database.dart';
import '../../tasks/task_test_support.dart';

/// Real schema / constraint / index tests for the `attachments` table
/// (task 10.3).
///
/// **Validates: Requirements R-NOTE-006, R-SEC-002, R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;
  late String profile;

  setUp(() async {
    db = openSchemaDatabase();
    profile = await insertProfile(db);
    await insertLifeArea(db, profile);
    await db.customStatement(
      'INSERT INTO notes '
      '(id, profile_id, life_area_id, title, normalized_title, body, '
      'content_hash, pinned, rank, revision, created_at_utc, updated_at_utc) '
      "VALUES ('note-1', ?, 'area-1', 'N', 'n', 'b', 'h', 0, 'm', 1, 0, 0)",
      <Object?>[profile],
    );
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  Future<void> insertAttachment(
    String id, {
    String noteId = 'note-1',
    String state = 'published',
    int? deletedAtUtc,
    int byteSize = 10,
    String pathToken = 'tok-1',
  }) => db.customStatement(
    'INSERT INTO attachments '
    '(id, profile_id, note_id, display_name, declared_mime, detected_mime, '
    'byte_size, content_hash, wrapped_dek, cipher_version, path_token, state, '
    'created_at_utc, updated_at_utc, deleted_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?)',
    <Object?>[
      id,
      profile,
      noteId,
      'photo.png',
      'image/png',
      'image/png',
      byteSize,
      'abc',
      'wrapped',
      'v1',
      pathToken,
      state,
      deletedAtUtc,
    ],
  );

  test('accepts a valid published attachment bound to its note', () async {
    await insertAttachment('a1');
    expect(await _count(db, 'attachments'), 1);
  });

  test('rejects an attachment whose note does not exist (R-GEN-002)', () async {
    await expectLater(insertAttachment('a1', noteId: 'ghost'), throwsSqlite);
  });

  test('rejects a negative byte size', () async {
    await expectLater(insertAttachment('a1', byteSize: -1), throwsSqlite);
  });

  test('rejects an unknown publication state', () async {
    await expectLater(insertAttachment('a1', state: 'weird'), throwsSqlite);
  });

  test('requires deleted rows to carry a deletion timestamp', () async {
    // state=deleted but deleted_at_utc null violates the paired CHECK.
    await expectLater(insertAttachment('a1', state: 'deleted'), throwsSqlite);
  });

  test('accepts a deleted row with a deletion timestamp', () async {
    await insertAttachment('a1', state: 'deleted', deletedAtUtc: 123);
    expect(await _count(db, 'attachments'), 1);
  });

  test('enforces a unique path token per profile', () async {
    await insertAttachment('a1', pathToken: 'dup');
    await expectLater(insertAttachment('a2', pathToken: 'dup'), throwsSqlite);
  });
}

Future<int> _count(ForgeSchemaDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table')
      .get();
  return rows.single.data['n'] as int;
}
