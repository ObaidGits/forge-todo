import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

import 'habit_test_support.dart';

/// Wave 6 risk gate — abstinence "clear a violation" correction path
/// (R-HABIT-005). A user may append a correcting check-in that supersedes a
/// prior violation. The superseded violation stays in the append-only audit
/// log, but the current projection no longer sees a violation, so the dated
/// occurrence completes when it closes with no (current) violation.
///
/// **Validates: Requirements R-HABIT-003, R-HABIT-005**
///
/// Evidence: [TEST-DB-HABIT-ABSTINENCE-CLEAR][MVP][TASK-7.6][R-HABIT-003,R-HABIT-005]
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

  test(
    'clearing a mistaken violation lets the occurrence complete on close',
    () async {
      final HabitId habitId = await createAbstinence();

      // Record a violation: the occurrence becomes missed immediately.
      final Result<Object> violate = await h.service.checkIn(
        commandId: h.nextCommandId('violate'),
        profileId: h.profileId,
        habitId: habitId,
        input: CheckInInput(
          onDate: LocalDate(2024, 6, 3),
          kind: ObservationInputKind.violation,
        ),
      );
      expect(violate, isA<Success<Object>>());
      final String logicalId = _extract(
        violate as Success<Object>,
        'logical_id',
      );
      expect(
        (await h.firstRow(
          'SELECT status FROM habit_occurrences WHERE habit_id = ?',
          <Object?>[habitId.value],
        ))!['status'],
        'missed',
      );

      // Retract the violation via an append-only correction.
      final Result<Object> cleared = await h.service.correctObservation(
        commandId: h.nextCommandId('clear'),
        profileId: h.profileId,
        habitId: habitId,
        input: CorrectObservationInput(
          logicalId: logicalId,
          kind: ObservationInputKind.clearViolation,
          note: 'logged by mistake',
        ),
      );
      expect(cleared, isA<Success<Object>>());

      // Append-only: the prior violation survives, but exactly one record is
      // current for the logical observation and it is not a violation.
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM habit_checkins WHERE logical_id = ?',
          <Object?>[logicalId],
        ),
        2,
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM habit_checkins WHERE logical_id = ? "
          "AND is_current = 1 AND event_kind = 'violation'",
          <Object?>[logicalId],
        ),
        0,
      );
      // The occurrence is no longer missed once the violation is cleared; before
      // close it returns to open.
      expect(
        (await h.firstRow(
          'SELECT status FROM habit_occurrences WHERE habit_id = ?',
          <Object?>[habitId.value],
        ))!['status'],
        'open',
      );

      // Closing with no current violation completes the abstinence occurrence.
      await h.service.closeOccurrence(
        commandId: h.nextCommandId('close'),
        profileId: h.profileId,
        habitId: habitId,
        input: CloseOccurrenceInput(onDate: LocalDate(2024, 6, 3)),
      );
      expect(
        (await h.firstRow(
          'SELECT status FROM habit_occurrences WHERE habit_id = ?',
          <Object?>[habitId.value],
        ))!['status'],
        'completed',
      );
    },
  );

  test('clearing a violation is rejected on a non-abstinence target', () async {
    final HabitId habitId = HabitId('habit-count');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-count'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Pushups',
        rule: dailyRule(),
        target: HabitTarget.count(5),
        rank: 'm',
      ),
    );
    final Result<Object> checkin = await h.service.checkIn(
      commandId: h.nextCommandId('value'),
      profileId: h.profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: LocalDate(2024, 6, 3),
        kind: ObservationInputKind.value,
        rawValue: 2,
      ),
    );
    final String logicalId = _extract(checkin as Success<Object>, 'logical_id');
    final Result<Object> result = await h.service.correctObservation(
      commandId: h.nextCommandId('bad-clear'),
      profileId: h.profileId,
      habitId: habitId,
      input: CorrectObservationInput(
        logicalId: logicalId,
        kind: ObservationInputKind.clearViolation,
      ),
    );
    expect(result, isA<Failed<Object>>());
    expect((result as Failed<Object>).failure.code, 'habit.kind_mismatch');
  });
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
