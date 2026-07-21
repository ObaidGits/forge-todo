import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';

import 'reminder_test_support.dart';

/// Integration proof that a reminder created through the durable command bus is
/// picked up by the rolling-horizon reconciler on launch, and that a subsequent
/// data change (disable / delete / toggle) reconciles the scheduled set on the
/// next lifecycle trigger (R-NOTIFY-001, R-NOTIFY-004, R-NOTIFY-006, R-GEN-005).
///
/// This closes the loop across the command service, the reminder read model,
/// the horizon reconciler, and the transport — the pieces the pure horizon and
/// per-service tests exercise in isolation.
///
/// **Validates: Requirements R-NOTIFY-001, R-NOTIFY-004, R-NOTIFY-006,
/// R-GEN-005**
void main() {
  Future<ReminderHarness> openWithReminder({required String seed}) async {
    final ReminderHarness h = await ReminderHarness.open(
      initialUtc: DateTime.utc(2024, 6, 28, 12),
    );
    final result = await h.commands.create(
      commandId: h.cmd('create-$seed'),
      profileId: h.profileId,
      reminderId: h.rid(seed),
      input: CreateReminderInput(
        ownerType: ReminderOwnerType.task,
        ownerId: 'task-$seed',
        triggerKind: ReminderTriggerKind.absolute,
        timezoneId: 'Etc/UTC',
        absoluteLocal: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(9, 0)),
      ),
    );
    expect(result.failureOrNull, isNull);
    return h;
  }

  test('[TEST-NOTIFY-RECONCILE-INTEGRATION-001][MVP][TASK-4.8]'
      '[R-NOTIFY-001,R-NOTIFY-004,R-GEN-005] a committed reminder is scheduled on '
      'launch and disabling it cancels on the next reconcile', () async {
    final ReminderHarness h = await openWithReminder(seed: 'a');
    addTearDown(h.close);

    final ReconciliationOutcome launch = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.launch,
    );
    expect(launch.report.scheduledCount, 1);
    expect((await h.transport.pending()).single.reminderId, h.rid('a').value);

    // A per-reminder toggle (R-NOTIFY-006) is a durable data change; the next
    // reconcile pass cancels the now-ineligible reminder.
    final disabled = await h.commands.setEnabled(
      commandId: h.cmd('disable-a'),
      profileId: h.profileId,
      reminderId: h.rid('a'),
      enabled: false,
    );
    expect(disabled.failureOrNull, isNull);

    final ReconciliationOutcome afterDisable = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.dataChange,
    );
    expect(afterDisable.report.cancelledCount, 1);
    expect(await h.transport.pending(), isEmpty);
  });

  test('[TEST-NOTIFY-RECONCILE-INTEGRATION-002][MVP][TASK-4.8]'
      '[R-NOTIFY-004,R-GEN-005] deleting a reminder removes it from the scheduled '
      'horizon on reconcile', () async {
    final ReminderHarness h = await openWithReminder(seed: 'b');
    addTearDown(h.close);

    await h.service.reconcile(h.profileId.value, ReconciliationTrigger.launch);
    expect((await h.transport.pending()).length, 1);

    final deleted = await h.commands.delete(
      commandId: h.cmd('delete-b'),
      profileId: h.profileId,
      reminderId: h.rid('b'),
    );
    expect(deleted.failureOrNull, isNull);

    final ReconciliationOutcome afterDelete = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.dataChange,
    );
    expect(afterDelete.report.cancelledCount, 1);
    expect(await h.transport.pending(), isEmpty);
  });
}
