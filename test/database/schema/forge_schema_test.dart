import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/common.dart';

import 'schema_test_database.dart';

/// Real schema / constraint / index tests for the core data platform.
///
/// **Validates: Requirements R-GEN-002, R-GEN-005, R-SYNC-006, NFR-REL-001**
void main() {
  late ForgeSchemaDatabase db;

  setUp(() {
    db = openSchemaDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  group('given the profiles table when enforcing one active profile', () {
    test('then two active profiles are rejected', () async {
      await insertProfile(db, id: 'a');
      await expectLater(insertProfile(db, id: 'b'), throwsSqlite);
    });

    test('then multiple inactive profiles coexist with one active', () async {
      await insertProfile(db, id: 'a');
      await insertProfile(db, id: 'b', isActive: false);
      await insertProfile(db, id: 'c', isActive: false);
      final List<QueryRow> rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM profiles')
          .get();
      expect(rows.single.data['n'], 3);
    });

    test('then an out-of-range week_start is rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO profiles '
          '(id, display_name, locale, timezone_id, week_start, hour_format, '
          'is_active, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>['x', 'P', 'en', 'UTC', 9, 'h24', 0, 0, 0],
        ),
        throwsSqlite,
      );
    });

    test('then an unknown hour_format enum is rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO profiles '
          '(id, display_name, locale, timezone_id, week_start, hour_format, '
          'is_active, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>['x', 'P', 'en', 'UTC', 1, 'h48', 0, 0, 0],
        ),
        throwsSqlite,
      );
    });
  });

  group('given foreign keys when a referenced profile is absent', () {
    test('then a device with an unknown profile_id is rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO devices '
          '(id, profile_id, name, platform, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>['d1', 'ghost', 'Phone', 'android', 0],
        ),
        throwsSqlite,
      );
    });

    test('then a valid device row is accepted', () async {
      final String profile = await insertProfile(db);
      await db.customStatement(
        'INSERT INTO devices '
        '(id, profile_id, name, platform, created_at_utc) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>['d1', profile, 'Phone', 'android', 0],
      );
      final List<QueryRow> rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM devices')
          .get();
      expect(rows.single.data['n'], 1);
    });
  });

  group('given entity_tags when rejecting cross-profile references', () {
    test('then attaching another profile\'s tag is rejected', () async {
      final String owner = await insertProfile(db, id: 'owner');
      await insertProfile(db, id: 'other', isActive: false);
      final String tag = await insertTag(db, owner, id: 't-owner');
      // The composite (profile_id, tag_id) FK forbids the "other" profile from
      // referencing a tag that belongs to "owner".
      await expectLater(
        db.customStatement(
          'INSERT INTO entity_tags '
          '(profile_id, entity_type, entity_id, tag_id, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>['other', 'task', 'task-1', tag, 0],
        ),
        throwsSqlite,
      );
    });

    test('then attaching an owned tag succeeds', () async {
      final String owner = await insertProfile(db, id: 'owner');
      final String tag = await insertTag(db, owner);
      await db.customStatement(
        'INSERT INTO entity_tags '
        '(profile_id, entity_type, entity_id, tag_id, created_at_utc) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[owner, 'task', 'task-1', tag, 0],
      );
      final List<QueryRow> rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM entity_tags')
          .get();
      expect(rows.single.data['n'], 1);
    });
  });

  group('given life_areas when enforcing taxonomy uniqueness', () {
    Future<void> insertArea(
      String id,
      String profile, {
      String normalizedName = 'career',
      bool isDefault = false,
    }) => db.customStatement(
      'INSERT INTO life_areas '
      '(id, profile_id, name, normalized_name, rank, is_default, '
      'created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        profile,
        'Name',
        normalizedName,
        'a',
        isDefault ? 1 : 0,
        0,
        0,
      ],
    );

    test('then duplicate normalized names per profile are rejected', () async {
      final String profile = await insertProfile(db);
      await insertArea('area-1', profile);
      await expectLater(insertArea('area-2', profile), throwsSqlite);
    });

    test('then only one default area per profile is allowed', () async {
      final String profile = await insertProfile(db);
      await insertArea('area-1', profile, normalizedName: 'a', isDefault: true);
      await expectLater(
        insertArea('area-2', profile, normalizedName: 'b', isDefault: true),
        throwsSqlite,
      );
    });
  });

  group('given command receipts when keyed by (profile_id, command_id)', () {
    Future<void> insertReceipt(String profile, String commandId) =>
        db.customStatement(
          'INSERT INTO command_receipts '
          '(profile_id, command_id, request_hash, result_code, '
          'payload_version, commit_seq, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[profile, commandId, 'hash', 'ok', 1, 1, 0],
        );

    test('then a duplicate command id for one profile is rejected', () async {
      final String profile = await insertProfile(db);
      await insertReceipt(profile, 'cmd-1');
      await expectLater(insertReceipt(profile, 'cmd-1'), throwsSqlite);
    });

    test('then the same command id under two profiles coexists', () async {
      final String a = await insertProfile(db, id: 'a');
      final String b = await insertProfile(db, id: 'b', isActive: false);
      await insertReceipt(a, 'cmd-1');
      await insertReceipt(b, 'cmd-1');
      final List<QueryRow> rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM command_receipts')
          .get();
      expect(rows.single.data['n'], 2);
    });
  });

  group('given enum CHECK constraints when inserting invalid states', () {
    test('then an invalid pending_command_journal state is rejected', () async {
      final String profile = await insertProfile(db);
      await expectLater(
        db.customStatement(
          'INSERT INTO pending_command_journal '
          '(profile_id, command_id, command_type, schema_version, '
          'canonical_payload, original_result_code, original_payload_version, '
          'commit_seq, state, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[profile, 'c1', 'x', 1, '{}', 'ok', 1, 1, 'bogus', 0],
        ),
        throwsSqlite,
      );
    });

    test('then an invalid outbox op_kind is rejected', () async {
      final String profile = await insertProfile(db);
      await expectLater(
        db.customStatement(
          'INSERT INTO outbox_mutations '
          '(operation_id, profile_id, group_id, group_index, group_count, '
          'entity_type, entity_id, op_kind, snapshot_epoch, payload, '
          'next_attempt_utc, state, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'op1',
            profile,
            'g1',
            0,
            1,
            'task',
            't1',
            'frobnicate',
            1,
            '{}',
            0,
            'pending',
            0,
            0,
          ],
        ),
        throwsSqlite,
      );
    });
  });

  group('given schema_metadata when enforcing the singleton', () {
    test('then a second row (id != 1) is rejected', () async {
      await db.customStatement(
        'INSERT INTO schema_metadata '
        '(id, schema_version, cipher_version, build_id, generation_id, '
        'migration_state, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?)',
        <Object?>[1, 1, 'v1', 'b1', 'g1', 'active', 0],
      );
      await expectLater(
        db.customStatement(
          'INSERT INTO schema_metadata '
          '(id, schema_version, cipher_version, build_id, generation_id, '
          'migration_state, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[2, 1, 'v1', 'b1', 'g1', 'active', 0],
        ),
        throwsSqlite,
      );
    });
  });

  group('given measured indexes when planning core queries', () {
    test('then every named schema index is present', () async {
      final List<QueryRow> rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      for (final String expected in <String>[
        'ux_profiles_active',
        'ux_life_areas_name',
        'ux_life_areas_default',
        'ux_tags_name',
        'idx_outbox_ready',
        'ux_pending_command_group',
        'ux_sync_conflicts_artifact',
        'ux_aggregate_cache_key',
      ]) {
        expect(names, contains(expected), reason: 'missing index $expected');
      }
    });

    test('then the outbox-ready query uses idx_outbox_ready', () async {
      final List<QueryRow> rows = await db
          .customSelect(
            'EXPLAIN QUERY PLAN SELECT operation_id FROM outbox_mutations '
            "WHERE profile_id = 'p' AND state = 'pending' "
            'ORDER BY next_attempt_utc, operation_id',
          )
          .get();
      final String plan = rows
          .map((QueryRow r) => r.data['detail'] as String)
          .join(' | ');
      expect(plan, contains('idx_outbox_ready'));
    });
  });
}
