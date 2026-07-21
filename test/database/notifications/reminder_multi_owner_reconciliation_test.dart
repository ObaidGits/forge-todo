import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';

import 'reminder_test_support.dart';

final class _FixedSettings implements NotificationSettingsStore {
  const _FixedSettings(this.settings);
  final NotificationSettings settings;

  @override
  Future<NotificationSettings> load(String profileId) async => settings;
}

Future<void> _createAbsolute(
  ReminderHarness h, {
  required String seed,
  required ReminderOwnerType ownerType,
  required LocalDateTime local,
}) async {
  final result = await h.commands.create(
    commandId: h.cmd('create-$seed'),
    profileId: h.profileId,
    reminderId: h.rid(seed),
    input: CreateReminderInput(
      ownerType: ownerType,
      ownerId: '${ownerType.wire}-$seed',
      triggerKind: ReminderTriggerKind.absolute,
      timezoneId: 'Etc/UTC',
      absoluteLocal: local,
    ),
  );
  expect(result.failureOrNull, isNull);
}

/// Task 7.5: the one unified reminder scheduling service reconciles reminders
/// for habits, study, and focus (deadline) alongside tasks, on the R-NOTIFY-004
/// lifecycle triggers, with per-category control (R-NOTIFY-006).
///
/// **Validates: Requirements R-NOTIFY-001, R-NOTIFY-004, R-NOTIFY-006**
///
/// Evidence: [TEST-DB-NOTIFY-MULTIOWNER][MVP][TASK-7.5]
void main() {
  LocalDateTime at(int day, int hour) =>
      LocalDateTime(LocalDate(2024, 6, day), LocalTime(hour, 0));

  test(
    'one launch pass reconciles habit, study, and focus reminders together',
    () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 1, 12),
      );
      addTearDown(h.close);

      await _createAbsolute(
        h,
        seed: 'habit',
        ownerType: ReminderOwnerType.habit,
        local: at(2, 9),
      );
      await _createAbsolute(
        h,
        seed: 'study',
        ownerType: ReminderOwnerType.study,
        local: at(2, 10),
      );
      // Focus/deadline prompts flow through the shared `deadline` owner type.
      await _createAbsolute(
        h,
        seed: 'focus',
        ownerType: ReminderOwnerType.deadline,
        local: at(2, 11),
      );

      final ReconciliationOutcome outcome = await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );

      // All three non-task owners are scheduled through the single service.
      expect(outcome.report.scheduledCount, 3);
      final List<ScheduledNotification> pending = await h.transport.pending();
      expect(
        pending.map((ScheduledNotification n) => n.category).toSet(),
        <ReminderCategory>{
          ReminderCategory.habit,
          ReminderCategory.study,
          ReminderCategory.deadline,
        },
      );

      // Each reminder row records its scheduled delivery state (R-NOTIFY-003).
      for (final String seed in <String>['habit', 'study', 'focus']) {
        final Map<String, Object?>? row = await h.firstRow(
          'SELECT delivery_status FROM reminders WHERE id = ?',
          <Object?>[h.rid(seed).value],
        );
        expect(row!['delivery_status'], 'scheduled');
      }
    },
  );

  test('disabling the habit category drops only habit reminders '
      '(R-NOTIFY-006)', () async {
    final NotificationSettings settings = NotificationSettings.defaults()
        .copyWith(
          categoryEnabled: <ReminderCategory, bool>{
            for (final ReminderCategory c in ReminderCategory.values) c: true,
            ReminderCategory.habit: false,
          },
        );
    final ReminderHarness h = await ReminderHarness.open(
      initialUtc: DateTime.utc(2024, 6, 1, 12),
      settingsStore: _FixedSettings(settings),
    );
    addTearDown(h.close);

    await _createAbsolute(
      h,
      seed: 'habit',
      ownerType: ReminderOwnerType.habit,
      local: at(2, 9),
    );
    await _createAbsolute(
      h,
      seed: 'study',
      ownerType: ReminderOwnerType.study,
      local: at(2, 10),
    );

    final ReconciliationOutcome outcome = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.launch,
    );

    // Only the study reminder is scheduled; the habit one is deliberately
    // skipped, not errored.
    expect(outcome.report.scheduledCount, 1);
    final List<ScheduledNotification> pending = await h.transport.pending();
    expect(pending.single.category, ReminderCategory.study);

    final Map<String, Object?>? habitRow = await h.firstRow(
      'SELECT delivery_status FROM reminders WHERE id = ?',
      <Object?>[h.rid('habit').value],
    );
    expect(habitRow!['delivery_status'], 'skipped');
  });

  test('a resume pass after data change is idempotent for all owner types '
      '(R-NOTIFY-004)', () async {
    final ReminderHarness h = await ReminderHarness.open(
      initialUtc: DateTime.utc(2024, 6, 1, 12),
    );
    addTearDown(h.close);

    await _createAbsolute(
      h,
      seed: 'habit',
      ownerType: ReminderOwnerType.habit,
      local: at(2, 9),
    );
    await _createAbsolute(
      h,
      seed: 'focus',
      ownerType: ReminderOwnerType.deadline,
      local: at(2, 11),
    );

    final ReconciliationOutcome first = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.launch,
    );
    expect(first.report.scheduledCount, 2);

    final ReconciliationOutcome second = await h.service.reconcile(
      h.profileId.value,
      ReconciliationTrigger.resume,
    );
    expect(second.report.scheduledCount, 0);
    expect(second.report.cancelledCount, 0);
    expect((await h.transport.pending()).length, 2);
  });
}
