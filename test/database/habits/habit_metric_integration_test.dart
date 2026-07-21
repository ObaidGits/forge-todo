import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

import 'habit_test_support.dart';

/// End-to-end metric-policy-v1 streak and consistency over real occurrence
/// projections (R-HABIT-004, R-HABIT-007).
void main() {
  late HabitHarness h;

  setUp(() async {
    h = await HabitHarness.open(initialUtc: DateTime.utc(2024, 6, 3, 9));
  });

  tearDown(() async {
    await h.close();
  });

  Future<HabitId> createDaily() async {
    final HabitId habitId = HabitId('habit-daily');
    await h.service.createHabit(
      commandId: h.nextCommandId('create'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Journal',
        rule: HabitScheduleRule(
          frequency: HabitFrequency.daily,
          scheduleKind: HabitScheduleKind.dated,
          start: LocalDate(2024, 6, 3),
          timezoneId: 'Etc/UTC',
        ),
        target: HabitTarget.boolean(),
        rank: 'm',
      ),
    );
    return habitId;
  }

  Future<void> complete(HabitId habitId, LocalDate date, String seed) =>
      h.service.checkIn(
        commandId: h.nextCommandId(seed),
        profileId: h.profileId,
        habitId: habitId,
        input: CheckInInput(
          onDate: date,
          kind: ObservationInputKind.booleanTrue,
        ),
      );

  test(
    'a skip is neutral for streak but stays in the consistency denominator',
    () async {
      final HabitId habitId = await createDaily();
      await complete(habitId, LocalDate(2024, 6, 3), 'd1');
      await complete(habitId, LocalDate(2024, 6, 4), 'd2');
      await h.service.skipOccurrence(
        commandId: h.nextCommandId('skip3'),
        profileId: h.profileId,
        habitId: habitId,
        input: SkipOccurrenceInput(
          onDate: LocalDate(2024, 6, 5),
          reason: 'sick',
        ),
      );
      await complete(habitId, LocalDate(2024, 6, 6), 'd4');

      final int streak = await h.reads.currentStreak(
        h.profileId.value,
        habitId.value,
        fromIso: '2024-06-01',
        toIso: '2024-06-30',
      );
      expect(streak, 3);

      final HabitConsistency consistency = await h.reads.consistency(
        h.profileId.value,
        habitId.value,
        fromIso: '2024-06-01',
        toIso: '2024-06-30',
      );
      expect(consistency.completed, 3);
      expect(consistency.denominator, 4);
      expect(consistency.ratio, closeTo(0.75, 1e-9));
    },
  );

  test('paused occurrences are ignored by both metrics', () async {
    final HabitId habitId = await createDaily();
    await complete(habitId, LocalDate(2024, 6, 3), 'd1');
    // Pause covering 2024-06-04.
    await h.service.pauseHabit(
      commandId: h.nextCommandId('pause'),
      profileId: h.profileId,
      habitId: habitId,
      input: PauseHabitInput(
        startDate: LocalDate(2024, 6, 4),
        endDate: LocalDate(2024, 6, 4),
      ),
    );
    // An occurrence materialized on the paused day is ineligible.
    await h.service.closeOccurrence(
      commandId: h.nextCommandId('close-paused'),
      profileId: h.profileId,
      habitId: habitId,
      input: CloseOccurrenceInput(onDate: LocalDate(2024, 6, 4)),
    );
    await complete(habitId, LocalDate(2024, 6, 5), 'd3');

    final HabitConsistency consistency = await h.reads.consistency(
      h.profileId.value,
      habitId.value,
      fromIso: '2024-06-01',
      toIso: '2024-06-30',
    );
    // Two eligible occurrences (06-03, 06-05), both completed; the paused
    // 06-04 is excluded.
    expect(consistency.denominator, 2);
    expect(consistency.completed, 2);

    final int streak = await h.reads.currentStreak(
      h.profileId.value,
      habitId.value,
      fromIso: '2024-06-01',
      toIso: '2024-06-30',
    );
    expect(streak, 2);
  });
}
