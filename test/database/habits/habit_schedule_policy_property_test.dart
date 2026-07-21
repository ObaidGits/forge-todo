import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

import 'habit_test_support.dart';

/// Wave 6 risk gate — generative schedule-policy suite (R-HABIT-001,
/// R-HABIT-003). Editing schedule or target semantics creates a successor
/// version at an explicit effective occurrence key and NEVER reinterprets prior
/// occurrences. Every materialized occurrence binds the immutable schedule/
/// target version effective at its deterministic key, and the version boundary
/// is half-open: an anchor strictly before the effective key stays on the
/// predecessor, and the effective key itself binds the successor.
///
/// **Validates: Requirements R-HABIT-001, R-HABIT-003**
///
/// Evidence: [TEST-DB-HABIT-SCHEDULE-PROP][MVP][TASK-7.6][R-HABIT-001,R-HABIT-003]
void main() {
  late HabitHarness h;

  setUp(() async {
    h = await HabitHarness.open(initialUtc: DateTime.utc(2024, 6, 1, 9));
  });

  tearDown(() async {
    await h.close();
  });

  HabitScheduleRule dailyAt(LocalDate start) => HabitScheduleRule(
    frequency: HabitFrequency.daily,
    scheduleKind: HabitScheduleKind.dated,
    start: start,
    timezoneId: 'Etc/UTC',
  );

  Future<HabitId> createBooleanDaily(LocalDate start, String seed) async {
    final HabitId habitId = HabitId('habit-$seed');
    await h.service.createHabit(
      commandId: h.nextCommandId('create-$seed'),
      profileId: h.profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: h.lifeAreaId.value,
        title: 'Habit $seed',
        rule: dailyAt(start),
        target: HabitTarget.boolean(),
        rank: 'm',
      ),
    );
    return habitId;
  }

  Future<String?> materializeVersionId(
    HabitId habitId,
    LocalDate onDate,
  ) async {
    await h.service.closeOccurrence(
      commandId: h.nextCommandId('close-${habitId.value}-${onDate.iso}'),
      profileId: h.profileId,
      habitId: habitId,
      input: CloseOccurrenceInput(onDate: onDate),
    );
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT schedule_version_id FROM habit_occurrences '
      'WHERE habit_id = ? AND occurrence_key = ?',
      <Object?>[habitId.value, onDate.iso],
    );
    return row?['schedule_version_id'] as String?;
  }

  test(
    'occurrences bind the version effective at their key across two edits and '
    'prior occurrences are never reinterpreted',
    () async {
      final LocalDate start = LocalDate(2024, 6, 1);
      for (final int seed in <int>[1, 7, 42, 2024, 9973]) {
        final Random random = Random(seed);
        final HabitId habitId = await createBooleanDaily(start, 's$seed');

        // A pre-existing occurrence created BEFORE any edit; its bound version
        // must not change when later successors are appended.
        final int preOffset = 1 + random.nextInt(2); // within v1's window
        final LocalDate preAnchor = start.addDays(preOffset);
        final String? preVersionBefore = await materializeVersionId(
          habitId,
          preAnchor,
        );
        expect(preVersionBefore, isNotNull);

        // Successor boundaries strictly after the pre-existing occurrence.
        final LocalDate e1 = start.addDays(preOffset + 2 + random.nextInt(3));
        final LocalDate e2 = e1.addDays(2 + random.nextInt(3));

        // Edit 1 at e1 changes the target kind to count (a positive integer).
        await h.service.editSchedule(
          commandId: h.nextCommandId('edit1-$seed'),
          profileId: h.profileId,
          habitId: habitId,
          input: EditScheduleInput(
            effectiveKey: e1,
            rule: dailyAt(e1),
            target: HabitTarget.count(2),
          ),
        );
        // Edit 2 at e2 changes the target kind to abstinence.
        await h.service.editSchedule(
          commandId: h.nextCommandId('edit2-$seed'),
          profileId: h.profileId,
          habitId: habitId,
          input: EditScheduleInput(
            effectiveKey: e2,
            rule: dailyAt(e2),
            target: HabitTarget.abstinence(),
          ),
        );

        // Immutability: the pre-existing occurrence still binds its original
        // version (R-HABIT-003 "never reinterprets prior occurrences").
        final Map<String, Object?>? preRow = await h.firstRow(
          'SELECT schedule_version_id FROM habit_occurrences '
          'WHERE habit_id = ? AND occurrence_key = ?',
          <Object?>[habitId.value, preAnchor.iso],
        );
        expect(preRow!['schedule_version_id'], preVersionBefore);

        // The three immutable versions, ordered.
        final List<Map<String, Object?>> versions = await h.rows(
          'SELECT id, version, target_kind, effective_occurrence_key '
          'FROM habit_schedules WHERE habit_id = ? ORDER BY version',
          <Object?>[habitId.value],
        );
        expect(versions, hasLength(3));
        final String v1 = versions[0]['id']! as String;
        final String v2 = versions[1]['id']! as String;
        final String v3 = versions[2]['id']! as String;
        expect(versions[0]['target_kind'], 'boolean');
        expect(versions[1]['target_kind'], 'count');
        expect(versions[2]['target_kind'], 'abstinence');
        // pre-existing occurrence sits in v1's window.
        expect(preVersionBefore, v1);

        // Probe random anchors across the whole range and assert the half-open
        // boundary binding.
        for (int i = 0; i < 12; i++) {
          final LocalDate anchor = start.addDays(random.nextInt(20));
          if (anchor.iso == preAnchor.iso) {
            continue;
          }
          final String? bound = await materializeVersionId(habitId, anchor);
          final String expected;
          if (anchor < e1) {
            expected = v1;
          } else if (anchor < e2) {
            expected = v2;
          } else {
            expected = v3;
          }
          expect(
            bound,
            expected,
            reason:
                'anchor ${anchor.iso} with e1=${e1.iso} e2=${e2.iso} '
                'must bind $expected',
          );
        }
      }
    },
  );
}
