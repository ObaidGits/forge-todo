import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

import 'reminder_test_support.dart';

/// Real Drift-backed tests that a workout participates in the one unified
/// reminder model as a first-class owner type in V1 (task 10.5,
/// R-NOTIFY-001 "V1 adds workout reminders when fitness exists").
///
/// **Validates: Requirements R-NOTIFY-001, R-GEN-005**
///
/// Evidence: [TEST-FIT-REMINDER-001][V1][TASK-10.5]
void main() {
  group('given the unified reminder command service', () {
    test('creates a workout reminder through the one service', () async {
      final ReminderHarness h = await ReminderHarness.open();
      addTearDown(h.close);

      final result = await h.commands.create(
        commandId: h.cmd('c1'),
        profileId: h.profileId,
        reminderId: h.rid('w'),
        input: CreateReminderInput(
          ownerType: ReminderOwnerType.workout,
          ownerId: 'workout-a',
          triggerKind: ReminderTriggerKind.absolute,
          timezoneId: 'America/New_York',
          absoluteLocal: LocalDateTime(LocalDate(2024, 7, 1), LocalTime(18, 0)),
        ),
      );
      expect(result.failureOrNull, isNull);

      // The reminder persists with the workout owner and its default workout
      // category so a person can silence workout prompts independently
      // (R-NOTIFY-006).
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT owner_type, category FROM reminders WHERE id = ?',
        <Object?>[h.rid('w').value],
      );
      expect(row, isNotNull);
      expect(row!['owner_type'], 'workout');
      expect(row['category'], 'workout');
    });
  });

  group('given the reminders schema', () {
    test(
      'accepts the workout owner but still rejects an unknown owner',
      () async {
        final ReminderHarness h = await ReminderHarness.open();
        addTearDown(h.close);

        Future<void> insert(
          String id,
          String ownerType,
        ) => h.db.customStatement(
          'INSERT INTO reminders '
          '(id, profile_id, owner_type, owner_id, category, trigger_kind, '
          'absolute_local, offset_minutes, timezone_id, dst_policy, enabled, '
          'delivery_status, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 1, ?, 0, 0)',
          <Object?>[
            id,
            h.profileId.value,
            ownerType,
            'owner-1',
            ownerType,
            'absolute',
            '2024-07-01T18:00:00',
            'Etc/UTC',
            'forward_gap_earlier_overlap',
            'pending',
          ],
        );

        // The widened CHECK admits the workout owner…
        await insert('ok-workout', 'workout');
        expect(
          await h.scalarInt(
            "SELECT COUNT(*) FROM reminders WHERE owner_type = 'workout'",
          ),
          1,
        );

        // …while an unrecognized owner type is still rejected (constraint intact).
        Object? caught;
        try {
          await insert('bad-owner', 'gizmo');
        } on Object catch (error) {
          caught = error;
        }
        expect(caught, isNotNull);
      },
    );
  });
}
