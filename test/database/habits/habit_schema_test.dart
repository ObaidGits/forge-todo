import 'package:flutter_test/flutter_test.dart';

import 'habit_test_support.dart';

/// Authoritative habit target-kind schema constraints (data-model §3;
/// R-HABIT-002). The database rejects illegal target configurations regardless
/// of the write path.
void main() {
  late HabitHarness h;

  setUp(() async {
    h = await HabitHarness.open();
    await _insertHabit(h);
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> insertSchedule({
    required String id,
    required String targetKind,
    int? targetValue,
    String? unit,
    String? displayUnit,
  }) async {
    await h.db.customStatement(
      'INSERT INTO habit_schedules '
      '(id, profile_id, habit_id, version, effective_occurrence_key, '
      'frequency, schedule_kind, "interval", week_start, timezone_id, '
      'start_date, target_kind, target_value, unit, display_unit, '
      'rule_version, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, 1, ?, ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, 1, 0, 0)',
      <Object?>[
        id,
        h.profileId.value,
        'habit-1',
        '2024-06-03',
        'daily',
        'dated',
        'Etc/UTC',
        '2024-06-03',
        targetKind,
        targetValue,
        unit,
        displayUnit,
      ],
    );
  }

  test('accepts a valid count target (positive value, no unit)', () async {
    await insertSchedule(id: 's-count', targetKind: 'count', targetValue: 5);
    expect(await h.scalar('SELECT COUNT(*) FROM habit_schedules'), 1);
  });

  test('rejects a count target with a unit', () async {
    expect(
      () => insertSchedule(
        id: 's-count-bad',
        targetKind: 'count',
        targetValue: 5,
        unit: 'reps',
      ),
      throwsA(anything),
    );
  });

  test('rejects a boolean target that carries a target value', () async {
    expect(
      () => insertSchedule(
        id: 's-bool-bad',
        targetKind: 'boolean',
        targetValue: 1,
      ),
      throwsA(anything),
    );
  });

  test('rejects an abstinence target that carries a unit', () async {
    expect(
      () =>
          insertSchedule(id: 's-abs-bad', targetKind: 'abstinence', unit: 'ml'),
      throwsA(anything),
    );
  });

  test('rejects a quantity target with no unit', () async {
    expect(
      () => insertSchedule(
        id: 's-qty-bad',
        targetKind: 'quantity',
        targetValue: 2000,
      ),
      throwsA(anything),
    );
  });

  test('rejects a duration target with no display unit', () async {
    expect(
      () => insertSchedule(
        id: 's-dur-bad',
        targetKind: 'duration',
        targetValue: 1800,
      ),
      throwsA(anything),
    );
  });

  test('rejects a non-positive numeric target', () async {
    expect(
      () => insertSchedule(id: 's-zero', targetKind: 'count', targetValue: 0),
      throwsA(anything),
    );
  });

  test('enforces one current check-in per logical observation', () async {
    await insertSchedule(id: 's-ok', targetKind: 'boolean');
    await h.db.customStatement(
      'INSERT INTO habit_occurrences '
      '(id, profile_id, habit_id, schedule_version_id, occurrence_key, '
      'anchor_date, status, normalized_total, is_paused, created_at_utc, '
      'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0)',
      <Object?>[
        'occ-1',
        h.profileId.value,
        'habit-1',
        's-ok',
        '2024-06-03',
        '2024-06-03',
        'open',
      ],
    );

    Future<void> insertCheckin(String id, {required bool current}) =>
        h.db.customStatement(
          'INSERT INTO habit_checkins '
          '(id, profile_id, habit_id, occurrence_id, logical_id, event_kind, '
          'recorded_at_utc, version, is_current, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?, 0)',
          <Object?>[
            id,
            h.profileId.value,
            'habit-1',
            'occ-1',
            'logical-1',
            'true',
            current ? 1 : 0,
          ],
        );

    await insertCheckin('c-1', current: true);
    // A second current record for the same logical id violates the partial
    // unique index.
    expect(() => insertCheckin('c-2', current: true), throwsA(anything));
    // A superseded (non-current) record for the same logical id is allowed.
    await insertCheckin('c-3', current: false);
    expect(
      await h.scalar(
        'SELECT COUNT(*) FROM habit_checkins WHERE logical_id = ?',
        <Object?>['logical-1'],
      ),
      2,
    );
  });
}

Future<void> _insertHabit(HabitHarness h) async {
  await h.db.customStatement(
    'INSERT INTO habits '
    '(id, profile_id, life_area_id, title, current_schedule_version_id, '
    'status, rank, revision, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, 0)',
    <Object?>[
      'habit-1',
      h.profileId.value,
      h.lifeAreaId.value,
      'Test',
      's-placeholder',
      'active',
      'm',
    ],
  );
}
