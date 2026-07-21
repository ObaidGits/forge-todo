import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/common.dart';

import '../schema/schema_test_database.dart';
import 'task_test_support.dart';

/// Real schema / constraint / index tests for the recurrence tables.
///
/// **Validates: Requirements R-TASK-005, R-TASK-006, R-TASK-007, R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;
  late String profile;

  setUp(() async {
    db = openSchemaDatabase();
    profile = await insertProfile(db);
    await insertLifeArea(db, profile);
    await db.customStatement(
      'INSERT INTO tasks '
      '(id, profile_id, life_area_id, title, status, priority, rank, '
      'created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>['task-1', profile, 'area-1', 'T', 'open', 'none', 'm', 0, 0],
    );
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  Future<void> insertRule(
    String id, {
    String taskId = 'task-1',
    String series = 's1',
    int version = 1,
    String frequency = 'daily',
    int interval = 1,
    int? count,
    String? until,
    int? timeOfDay,
    String effective = '2024-06-01',
    String start = '2024-06-01',
  }) => db.customStatement(
    'INSERT INTO recurrence_rules '
    '(id, profile_id, task_id, series_id, version, effective_occurrence_key, '
    'frequency, "interval", count_limit, until_date, timezone_id, start_date, '
    'time_of_day_seconds, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      profile,
      taskId,
      series,
      version,
      effective,
      frequency,
      interval,
      count,
      until,
      'Etc/UTC',
      start,
      timeOfDay,
      0,
      0,
    ],
  );

  group('recurrence_rules constraints', () {
    test('accepts a valid rule', () async {
      await insertRule('r1');
      expect(await _count(db, 'recurrence_rules'), 1);
    });

    test('rejects an unknown frequency', () async {
      await expectLater(insertRule('r1', frequency: 'hourly'), throwsSqlite);
    });

    test('rejects interval < 1', () async {
      await expectLater(insertRule('r1', interval: 0), throwsSqlite);
    });

    test('rejects both count and until bounds', () async {
      await expectLater(
        insertRule('r1', count: 3, until: '2024-07-01'),
        throwsSqlite,
      );
    });

    test('rejects an out-of-range time of day', () async {
      await expectLater(insertRule('r1', timeOfDay: 86400), throwsSqlite);
    });

    test('rejects a rule under an unknown task', () async {
      await expectLater(insertRule('r1', taskId: 'ghost'), throwsSqlite);
    });

    test('enforces unique series version', () async {
      await insertRule('r1');
      await expectLater(insertRule('r2'), throwsSqlite);
    });
  });

  group('task_occurrences constraints', () {
    Future<void> insertOccurrence(
      String id, {
      String key = '2024-06-01',
      String status = 'open',
      String versionId = 'r1',
    }) => db.customStatement(
      'INSERT INTO task_occurrences '
      '(id, profile_id, task_id, schedule_version_id, '
      'original_schedule_version_id, occurrence_key, status, '
      'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[id, profile, 'task-1', versionId, versionId, key, status, 0, 0],
    );

    setUp(() async {
      await insertRule('r1');
    });

    test('accepts a valid occurrence', () async {
      await insertOccurrence('o1');
      expect(await _count(db, 'task_occurrences'), 1);
    });

    test('rejects an unknown status', () async {
      await expectLater(
        insertOccurrence('o1', status: 'pending'),
        throwsSqlite,
      );
    });

    test('rejects a duplicate occurrence key for one task', () async {
      await insertOccurrence('o1');
      await expectLater(insertOccurrence('o2'), throwsSqlite);
    });

    test('rejects an occurrence under an unknown schedule version', () async {
      await expectLater(
        insertOccurrence('o1', versionId: 'ghost'),
        throwsSqlite,
      );
    });
  });

  group('task_occurrence_events constraints', () {
    setUp(() async {
      await insertRule('r1');
      await db.customStatement(
        'INSERT INTO task_occurrences '
        '(id, profile_id, task_id, schedule_version_id, '
        'original_schedule_version_id, occurrence_key, status, '
        'created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'o1',
          profile,
          'task-1',
          'r1',
          'r1',
          '2024-06-01',
          'open',
          0,
          0,
        ],
      );
    });

    Future<void> insertEvent(String id, {String kind = 'complete'}) =>
        db.customStatement(
          'INSERT INTO task_occurrence_events '
          '(id, profile_id, occurrence_id, event_kind, payload_version, '
          'occurred_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>[id, profile, 'o1', kind, 1, 0],
        );

    test('accepts a valid event', () async {
      await insertEvent('e1');
      expect(await _count(db, 'task_occurrence_events'), 1);
    });

    test('rejects an unknown event kind', () async {
      await expectLater(insertEvent('e1', kind: 'archived'), throwsSqlite);
    });

    test('rejects an event under an unknown occurrence', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO task_occurrence_events '
          '(id, profile_id, occurrence_id, event_kind, payload_version, '
          'occurred_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>['e1', profile, 'ghost', 'complete', 1, 0],
        ),
        throwsSqlite,
      );
    });
  });

  group('measured indexes', () {
    test('every named recurrence index exists', () async {
      final List<QueryRow> rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      for (final String expected in <String>[
        'ux_recurrence_rules_profile_id',
        'ux_recurrence_rules_series_version',
        'ix_recurrence_rules_task',
        'ux_task_occurrences_profile_id',
        'ux_task_occurrences_key',
        'ix_task_occurrences_status',
        'ix_task_occurrence_events_occurrence_time',
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
