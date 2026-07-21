import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/reminder_action_service.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';

import 'reminder_test_support.dart';

Future<void> _create(
  ReminderHarness h, {
  required String seed,
  required String ownerId,
}) async {
  final result = await h.commands.create(
    commandId: h.cmd('create-$seed'),
    profileId: h.profileId,
    reminderId: h.rid(seed),
    input: CreateReminderInput(
      ownerType: ReminderOwnerType.task,
      ownerId: ownerId,
      triggerKind: ReminderTriggerKind.absolute,
      timezoneId: 'Etc/UTC',
      absoluteLocal: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(9, 0)),
    ),
  );
  expect(result.failureOrNull, isNull);
}

/// **Validates: Requirements R-NOTIFY-005, R-GEN-005**
void main() {
  group('given a committed idempotent notification action', () {
    test('dismiss commits locally, then cancels, and replays stably', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
      );
      addTearDown(h.close);
      await h.insertTask(id: 'task-a');
      await _create(h, seed: 'a', ownerId: 'task-a');
      await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );
      expect((await h.transport.pending()).length, 1);

      final ReminderActionService actions = ReminderActionService(
        reminderCommands: h.commands,
        transport: h.transport,
        taskCommands: h.tasks,
      );

      final Result<ReminderActionResult> first = await actions.handle(
        commandId: h.cmd('act-1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-a',
        action: ReminderAction.dismiss(),
      );
      expect(first.failureOrNull, isNull);
      final ReminderActionResult firstValue =
          (first as Success<ReminderActionResult>).value;
      expect(firstValue.committed.replayed, isFalse);
      expect(firstValue.dismissed, isTrue);

      // The local effect is durable and the OS placement is gone.
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT delivery_status FROM reminders WHERE id = ?',
        <Object?>[h.rid('a').value],
      );
      expect(row!['delivery_status'], 'skipped');
      expect((await h.transport.pending()), isEmpty);

      final int activityBefore = await h.scalarInt(
        'SELECT COUNT(*) FROM activity_events WHERE entity_id = ? '
        "AND event_type = 'reminder_dismissed'",
        <Object?>[h.rid('a').value],
      );
      expect(activityBefore, 1);

      // Replaying the exact same action id returns the stored result and
      // creates no duplicate effect (R-GEN-005 receipt replay).
      final Result<ReminderActionResult> replay = await actions.handle(
        commandId: h.cmd('act-1'),
        profileId: h.profileId,
        reminderId: h.rid('a'),
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-a',
        action: ReminderAction.dismiss(),
      );
      final ReminderActionResult replayValue =
          (replay as Success<ReminderActionResult>).value;
      expect(replayValue.committed.replayed, isTrue);
      expect(replayValue.committed.commitSeq, firstValue.committed.commitSeq);

      final int activityAfter = await h.scalarInt(
        'SELECT COUNT(*) FROM activity_events WHERE entity_id = ? '
        "AND event_type = 'reminder_dismissed'",
        <Object?>[h.rid('a').value],
      );
      expect(activityAfter, 1);
    });

    test('complete action completes the owner task idempotently', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
      );
      addTearDown(h.close);
      await h.insertTask(id: 'task-b');
      await _create(h, seed: 'b', ownerId: 'task-b');
      await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );

      final ReminderActionService actions = ReminderActionService(
        reminderCommands: h.commands,
        transport: h.transport,
        taskCommands: h.tasks,
      );

      final Result<ReminderActionResult> first = await actions.handle(
        commandId: h.cmd('complete-1'),
        profileId: h.profileId,
        reminderId: h.rid('b'),
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-b',
        action: ReminderAction.complete(),
      );
      expect(first.failureOrNull, isNull);

      final Map<String, Object?>? task = await h.firstRow(
        'SELECT status FROM tasks WHERE id = ?',
        <Object?>['task-b'],
      );
      expect(task!['status'], 'completed');
      expect((await h.transport.pending()), isEmpty);

      // Replay: task stays completed, no duplicate completion event.
      final Result<ReminderActionResult> replay = await actions.handle(
        commandId: h.cmd('complete-1'),
        profileId: h.profileId,
        reminderId: h.rid('b'),
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-b',
        action: ReminderAction.complete(),
      );
      expect(
        (replay as Success<ReminderActionResult>).value.committed.replayed,
        isTrue,
      );
      final int completions = await h.scalarInt(
        'SELECT COUNT(*) FROM activity_events WHERE entity_id = ? '
        "AND event_type = 'completed'",
        <Object?>['task-b'],
      );
      expect(completions, 1);
    });

    test('snooze defers the reminder and reschedules on reconcile', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
      );
      addTearDown(h.close);
      await h.insertTask(id: 'task-c');
      await _create(h, seed: 'c', ownerId: 'task-c');
      await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );

      final ReminderActionService actions = ReminderActionService(
        reminderCommands: h.commands,
        transport: h.transport,
        taskCommands: h.tasks,
      );
      final Result<ReminderActionResult> snoozed = await actions.handle(
        commandId: h.cmd('snooze-1'),
        profileId: h.profileId,
        reminderId: h.rid('c'),
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-c',
        action: ReminderAction.snooze(30),
      );
      expect(snoozed.failureOrNull, isNull);

      final Map<String, Object?>? row = await h.firstRow(
        'SELECT snoozed_until_utc FROM reminders WHERE id = ?',
        <Object?>[h.rid('c').value],
      );
      expect(row!['snoozed_until_utc'], isNotNull);

      // Reconcile now places the reminder at the snooze instant (30 min out).
      await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.dataChange,
      );
      final int fire = (await h.transport.pending()).single.fireAtUtc;
      expect(fire, DateTime.utc(2024, 6, 28, 12, 30).microsecondsSinceEpoch);
    });
  });
}
