import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

import 'habit_test_support.dart';

/// Real Drift-backed habit command flows (R-HABIT-001..007).
void main() {
  late HabitHarness h;

  setUp(() async {
    h = await HabitHarness.open(initialUtc: DateTime.utc(2024, 6, 3, 9));
  });

  tearDown(() async {
    await h.close();
  });

  HabitScheduleRule dailyRule() => HabitScheduleRule(
    frequency: HabitFrequency.daily,
    scheduleKind: HabitScheduleKind.dated,
    start: LocalDate(2024, 6, 3),
    timezoneId: 'Etc/UTC',
  );

  Future<HabitId> createBoolean() async {
    final HabitId habitId = HabitId('habit-bool');
    final Result<Object> result = await h.service.createHabit(
      commandId: h.nextCommandId('create-bool'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Meditate',
        rule: dailyRule(),
        target: HabitTarget.boolean(),
        rank: 'm',
      ),
    );
    expect(result, isA<Success<Object>>());
    return habitId;
  }

  test(
    'createHabit materializes habit, schedule version and first occurrence',
    () async {
      final HabitId habitId = await createBoolean();
      expect(
        await h.scalar('SELECT COUNT(*) FROM habits WHERE id = ?', <Object?>[
          habitId.value,
        ]),
        1,
      );
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM habit_schedules WHERE habit_id = ?',
          <Object?>[habitId.value],
        ),
        1,
      );
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM habit_occurrences WHERE habit_id = ?',
          <Object?>[habitId.value],
        ),
        1,
      );
    },
  );

  test('a boolean true check-in completes the occurrence', () async {
    final HabitId habitId = await createBoolean();
    final Result<Object> result = await h.service.checkIn(
      commandId: h.nextCommandId('checkin-bool'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.booleanTrue,
      ),
    );
    expect(result, isA<Success<Object>>());
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT status FROM habit_occurrences WHERE habit_id = ?',
      <Object?>[habitId.value],
    );
    expect(row!['status'], 'completed');
  });

  test('count observations accumulate toward the target', () async {
    final HabitId habitId = HabitId('habit-count');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-count'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Pushups',
        rule: dailyRule(),
        target: HabitTarget.count(3),
        rank: 'm',
      ),
    );
    for (int i = 0; i < 2; i++) {
      await h.service.checkIn(
        commandId: h.nextCommandId('count-$i'),
        profileId: h.profileId,
        habitId: habitId,
        input: CheckInInput(
          onDate: LocalDate(2024, 6, 3),
          kind: ObservationInputKind.value,
          rawValue: 1,
        ),
      );
    }
    Map<String, Object?>? row = await h.firstRow(
      'SELECT status, normalized_total FROM habit_occurrences WHERE habit_id = ?',
      <Object?>[habitId.value],
    );
    expect(row!['status'], 'open');
    expect(row['normalized_total'], 2);

    await h.service.checkIn(
      commandId: h.nextCommandId('count-final'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 1,
      ),
    );
    row = await h.firstRow(
      'SELECT status, normalized_total FROM habit_occurrences WHERE habit_id = ?',
      <Object?>[habitId.value],
    );
    expect(row!['status'], 'completed');
    expect(row['normalized_total'], 3);
  });

  test('quantity observations normalize incompatible-safe units', () async {
    final HabitId habitId = HabitId('habit-water');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-water'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Water',
        rule: dailyRule(),
        target: HabitTarget.quantity(targetValue: 2000, unit: 'ml'),
        rank: 'm',
      ),
    );
    // 1 litre normalizes to 1000 ml.
    await h.service.checkIn(
      commandId: h.nextCommandId('water-1'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 1,
        rawUnit: 'l',
      ),
    );
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT normalized_total FROM habit_occurrences WHERE habit_id = ?',
      <Object?>[habitId.value],
    );
    expect(row!['normalized_total'], 1000);
  });

  test('an incompatible-unit observation is rejected', () async {
    final HabitId habitId = HabitId('habit-water2');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-water2'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Water',
        rule: dailyRule(),
        target: HabitTarget.quantity(targetValue: 2000, unit: 'ml'),
        rank: 'm',
      ),
    );
    final Result<Object> result = await h.service.checkIn(
      commandId: h.nextCommandId('water-bad'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 1,
        rawUnit: 'kg',
      ),
    );
    expect(result, isA<Failed<Object>>());
    expect(
      (result as Failed<Object>).failure.code,
      'habit.invalid_observation',
    );
  });

  test('recording a value against a boolean target is rejected', () async {
    final HabitId habitId = await createBoolean();
    final Result<Object> result = await h.service.checkIn(
      commandId: h.nextCommandId('bad-kind'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 5,
      ),
    );
    expect(result, isA<Failed<Object>>());
    expect((result as Failed<Object>).failure.code, 'habit.kind_mismatch');
  });

  group('abstinence', () {
    Future<HabitId> createAbstinence() async {
      final HabitId habitId = HabitId('habit-abs');
      await h.service.createHabit(
        commandId: h.nextCommandId('create-abs'),
        profileId: h.profileId,
        habitId: habitId,
        input: CreateHabitInput(
          lifeAreaId: h.lifeAreaId.value,
          title: 'No sugar',
          rule: dailyRule(),
          target: HabitTarget.abstinence(),
          rank: 'm',
        ),
      );
      return habitId;
    }

    test('becomes missed on the first violation', () async {
      final HabitId habitId = await createAbstinence();
      await h.service.checkIn(
        commandId: h.nextCommandId('abs-violate'),
        profileId: h.profileId,
        habitId: habitId,
        input: CheckInInput(
          onDate: LocalDate(2024, 6, 3),
          kind: ObservationInputKind.violation,
        ),
      );
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT status FROM habit_occurrences WHERE habit_id = ?',
        <Object?>[habitId.value],
      );
      expect(row!['status'], 'missed');
    });

    test('completes on close with no violation', () async {
      final HabitId habitId = await createAbstinence();
      // Materialize the occurrence first via a close (resolves + closes).
      final Result<Object> result = await h.service.closeOccurrence(
        commandId: h.nextCommandId('abs-close'),
        profileId: h.profileId,
        habitId: habitId,
        input: CloseOccurrenceInput(onDate: LocalDate(2024, 6, 3)),
      );
      expect(result, isA<Success<Object>>());
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT status FROM habit_occurrences WHERE habit_id = ?',
        <Object?>[habitId.value],
      );
      expect(row!['status'], 'completed');
    });
  });

  test('a correcting check-in supersedes the prior observation', () async {
    final HabitId habitId = HabitId('habit-corr');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-corr'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Read',
        rule: dailyRule(),
        target: HabitTarget.count(10),
        rank: 'm',
      ),
    );
    final Result<Object> checkin = await h.service.checkIn(
      commandId: h.nextCommandId('corr-value'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 3,
      ),
    );
    final String logicalId = _extract(
      (checkin as Success<Object>),
      'logical_id',
    );

    await h.service.correctObservation(
      commandId: h.nextCommandId('corr-fix'),
      profileId: h.profileId,
      habitId: habitId,
      input: CorrectObservationInput(
        logicalId: logicalId,
        kind: ObservationInputKind.value,
        rawValue: 10,
      ),
    );
    // The prior record survives (append-only) but only one is current.
    expect(
      await h.scalar(
        'SELECT COUNT(*) FROM habit_checkins WHERE logical_id = ?',
        <Object?>[logicalId],
      ),
      2,
    );
    expect(
      await h.scalar(
        'SELECT COUNT(*) FROM habit_checkins WHERE logical_id = ? AND is_current = 1',
        <Object?>[logicalId],
      ),
      1,
    );
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT status, normalized_total FROM habit_occurrences WHERE habit_id = ?',
      <Object?>[habitId.value],
    );
    expect(row!['normalized_total'], 10);
    expect(row['status'], 'completed');
  });

  test(
    'editing schedule this-and-future closes the version and adds a successor',
    () async {
      final HabitId habitId = await createBoolean();
      final Result<Object> result = await h.service.editSchedule(
        commandId: h.nextCommandId('edit'),
        profileId: h.profileId,
        habitId: habitId,
        input: EditScheduleInput(
          effectiveKey: LocalDate(2024, 6, 10),
          rule: HabitScheduleRule(
            frequency: HabitFrequency.daily,
            scheduleKind: HabitScheduleKind.dated,
            start: LocalDate(2024, 6, 10),
            timezoneId: 'Etc/UTC',
            interval: 2,
          ),
          target: HabitTarget.boolean(),
        ),
      );
      expect(result, isA<Success<Object>>());
      // Two versions; the first is closed at the effective key.
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM habit_schedules WHERE habit_id = ?',
          <Object?>[habitId.value],
        ),
        2,
      );
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM habit_schedules WHERE habit_id = ? '
          'AND closed_at_occurrence_key = ?',
          <Object?>[habitId.value, '2024-06-10'],
        ),
        1,
      );
    },
  );

  test(
    'idempotent replay returns the stored result without duplicating rows',
    () async {
      final HabitId habitId = HabitId('habit-idem');
      final CommandId cmd = h.nextCommandId('idem-create');
      final CreateHabitInput input = CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Stretch',
        rule: dailyRule(),
        target: HabitTarget.boolean(),
        rank: 'm',
      );
      final Result<Object> first = await h.service.createHabit(
        commandId: cmd,
        profileId: h.profileId,
        habitId: habitId,
        input: input,
      );
      final Result<Object> second = await h.service.createHabit(
        commandId: cmd,
        profileId: h.profileId,
        habitId: habitId,
        input: input,
      );
      expect(first, isA<Success<Object>>());
      expect(second, isA<Success<Object>>());
      expect(
        await h.scalar('SELECT COUNT(*) FROM habits WHERE id = ?', <Object?>[
          habitId.value,
        ]),
        1,
      );
    },
  );
}

String _extract(Success<Object> success, String key) {
  final CommittedCommandResult value = success.value as CommittedCommandResult;
  final String payload = value.resultPayload!;
  final RegExp pattern = RegExp('"$key":"([^"]+)"');
  final Match? match = pattern.firstMatch(payload);
  if (match == null) {
    throw StateError('No $key in $payload');
  }
  return match.group(1)!;
}
