import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

import 'reminder_test_support.dart';

CreateReminderInput _absolute() => CreateReminderInput(
  ownerType: ReminderOwnerType.task,
  ownerId: 'task-a',
  triggerKind: ReminderTriggerKind.absolute,
  timezoneId: 'America/New_York',
  absoluteLocal: LocalDateTime(LocalDate(2024, 7, 1), LocalTime(9, 0)),
);

/// **Validates: Requirements R-NOTIFY-001, R-NOTIFY-006, R-GEN-005**
void main() {
  group('given the durable reminder command service', () {
    test('create writes a reminder row, receipt, and outbox group', () async {
      final ReminderHarness h = await ReminderHarness.open();
      addTearDown(h.close);

      final result = await h.commands.create(
        commandId: h.cmd('c1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        input: _absolute(),
      );
      expect(result.failureOrNull, isNull);

      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM reminders WHERE id = ?',
          <Object?>[h.rid('a').value],
        ),
        1,
      );
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM command_receipts WHERE command_id = ?',
          <Object?>[h.cmd('c1').value],
        ),
        1,
      );
      expect(
        await h.scalarInt(
          "SELECT COUNT(*) FROM outbox_mutations WHERE entity_type = 'reminder'",
        ),
        1,
      );
    });

    test('create is idempotent under the same command id', () async {
      final ReminderHarness h = await ReminderHarness.open();
      addTearDown(h.close);
      await h.commands.create(
        commandId: h.cmd('c1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        input: _absolute(),
      );
      final result = await h.commands.create(
        commandId: h.cmd('c1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        input: _absolute(),
      );
      expect(
        (result as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
      expect(await h.scalarInt('SELECT COUNT(*) FROM reminders'), 1);
    });

    test('set enabled toggles and delete soft-deletes', () async {
      final ReminderHarness h = await ReminderHarness.open();
      addTearDown(h.close);
      await h.commands.create(
        commandId: h.cmd('c1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        input: _absolute(),
      );

      await h.commands.setEnabled(
        commandId: h.cmd('e1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        enabled: false,
      );
      expect(
        await h.scalarInt(
          'SELECT enabled FROM reminders WHERE id = ?',
          <Object?>[h.rid('a').value],
        ),
        0,
      );

      await h.commands.delete(
        commandId: h.cmd('d1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
      );
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM reminders WHERE id = ? '
          'AND deleted_at_utc IS NOT NULL',
          <Object?>[h.rid('a').value],
        ),
        1,
      );
      // A disabled/deleted reminder is not returned as enabled.
      expect(await h.reads.enabledReminders(h.profileId.value), isEmpty);
    });

    test(
      'rejects a trigger with neither absolute nor offset populated',
      () async {
        final ReminderHarness h = await ReminderHarness.open();
        addTearDown(h.close);
        final result = await h.commands.create(
          commandId: h.cmd('c1'),
          profileId: h.profileId,
          reminderId: h.rid('a'),
          input: CreateReminderInput(
            ownerType: ReminderOwnerType.task,
            ownerId: 'task-a',
            triggerKind: ReminderTriggerKind.absolute,
            timezoneId: 'Etc/UTC',
          ),
        );
        expect(result.failureOrNull, isNotNull);
        expect(result.failureOrNull!.code, 'reminder.absolute_requires_local');
      },
    );
  });

  group('given the reminders schema', () {
    test('rejects a row populating both trigger forms', () async {
      final ReminderHarness h = await ReminderHarness.open();
      addTearDown(h.close);
      Object? caught;
      try {
        await h.db.customStatement(
          'INSERT INTO reminders '
          '(id, profile_id, owner_type, owner_id, category, trigger_kind, '
          'absolute_local, offset_minutes, timezone_id, dst_policy, enabled, '
          'delivery_status, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, 0)',
          <Object?>[
            'bad-1',
            h.profileId.value,
            'task',
            'task-a',
            'task',
            'absolute',
            '2024-07-01T09:00:00',
            30,
            'Etc/UTC',
            'forward_gap_earlier_overlap',
            'pending',
          ],
        );
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
    });
  });
}
