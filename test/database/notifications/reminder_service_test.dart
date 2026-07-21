import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

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
  required String timezoneId,
  required LocalDateTime local,
}) async {
  final result = await h.commands.create(
    commandId: h.cmd('create-$seed'),
    profileId: h.profileId,
    reminderId: h.rid(seed),
    input: CreateReminderInput(
      ownerType: ReminderOwnerType.task,
      ownerId: 'task-$seed',
      triggerKind: ReminderTriggerKind.absolute,
      timezoneId: timezoneId,
      absoluteLocal: local,
    ),
  );
  expect(result.failureOrNull, isNull);
}

/// **Validates: Requirements R-NOTIFY-001, R-NOTIFY-002, R-NOTIFY-004,
/// R-NOTIFY-006, R-GEN-004**
void main() {
  group('given deterministic timezone reconciliation', () {
    test('resolves a summer local time to the DST (EDT) instant', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
      );
      addTearDown(h.close);
      await _createAbsolute(
        h,
        seed: 'a',
        timezoneId: 'America/New_York',
        local: LocalDateTime(LocalDate(2024, 7, 1), LocalTime(9, 0)),
      );

      final ReconciliationOutcome outcome = await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );

      expect(outcome.report.scheduledCount, 1);
      final List<ScheduledNotification> pending = await h.transport.pending();
      expect(
        pending.single.fireAtUtc,
        DateTime.utc(2024, 7, 1, 13).microsecondsSinceEpoch,
      );
    });

    test(
      'resolves a winter local time to the standard (EST) instant',
      () async {
        final ReminderHarness h = await ReminderHarness.open(
          initialUtc: DateTime.utc(2024, 1, 10, 12),
        );
        addTearDown(h.close);
        await _createAbsolute(
          h,
          seed: 'a',
          timezoneId: 'America/New_York',
          local: LocalDateTime(LocalDate(2024, 1, 15), LocalTime(9, 0)),
        );

        await h.service.reconcile(
          h.profileId.value,
          ReconciliationTrigger.launch,
        );
        final List<ScheduledNotification> pending = await h.transport.pending();
        expect(
          pending.single.fireAtUtc,
          DateTime.utc(2024, 1, 15, 14).microsecondsSinceEpoch,
        );
      },
    );

    test(
      'travel does not move a reminder anchored to its own timezone',
      () async {
        final ReminderHarness h = await ReminderHarness.open(
          initialUtc: DateTime.utc(2024, 6, 28, 12),
          timezoneId: 'America/New_York',
        );
        addTearDown(h.close);
        await _createAbsolute(
          h,
          seed: 'a',
          timezoneId: 'America/New_York',
          local: LocalDateTime(LocalDate(2024, 7, 1), LocalTime(9, 0)),
        );

        await h.service.reconcile(
          h.profileId.value,
          ReconciliationTrigger.launch,
        );
        final int before = (await h.transport.pending()).single.fireAtUtc;

        // The device travels to Tokyo; a timezone-change reconciliation runs.
        h.clock.timezoneIdentifier = 'Asia/Tokyo';
        await h.service.reconcile(
          h.profileId.value,
          ReconciliationTrigger.timezoneChange,
        );
        final int after = (await h.transport.pending()).single.fireAtUtc;

        expect(after, before);
      },
    );
  });

  group('given the R-NOTIFY-004 lifecycle triggers', () {
    test(
      'a no-op resume pass reschedules nothing (idempotent horizon)',
      () async {
        final ReminderHarness h = await ReminderHarness.open(
          initialUtc: DateTime.utc(2024, 6, 28, 12),
        );
        addTearDown(h.close);
        await _createAbsolute(
          h,
          seed: 'a',
          timezoneId: 'Etc/UTC',
          local: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(9, 0)),
        );

        final ReconciliationOutcome first = await h.service.reconcile(
          h.profileId.value,
          ReconciliationTrigger.launch,
        );
        expect(first.report.scheduledCount, 1);

        final ReconciliationOutcome second = await h.service.reconcile(
          h.profileId.value,
          ReconciliationTrigger.resume,
        );
        expect(second.report.scheduledCount, 0);
        expect(second.report.cancelledCount, 0);
        expect((await h.transport.pending()).length, 1);
      },
    );

    test('permission denial defers, and a later grant schedules', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
        capability: const SchedulerCapability(
          permission: PermissionStatus.denied,
          available: true,
          exactAlarms: true,
          actionsSupported: true,
        ),
      );
      addTearDown(h.close);
      await _createAbsolute(
        h,
        seed: 'a',
        timezoneId: 'Etc/UTC',
        local: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(9, 0)),
      );

      final ReconciliationOutcome denied = await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );
      expect(denied.report.scheduledCount, 0);
      expect(
        denied.diagnostics.any(
          (ReminderDiagnostic d) =>
              d.code == ReminderDiagnosticCode.permissionDenied,
        ),
        isTrue,
      );
      // The reminder row records the skipped delivery state (R-NOTIFY-003).
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT delivery_status, last_diagnostic_code FROM reminders '
        'WHERE id = ?',
        <Object?>[h.rid('a').value],
      );
      expect(row!['delivery_status'], 'skipped');
      expect(row['last_diagnostic_code'], 'permissionDenied');

      h.transport.setCapability(SchedulerCapability.fullyCapable());
      final ReconciliationOutcome granted = await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.permissionChange,
      );
      expect(granted.report.scheduledCount, 1);
      final Map<String, Object?>? scheduledRow = await h.firstRow(
        'SELECT delivery_status FROM reminders WHERE id = ?',
        <Object?>[h.rid('a').value],
      );
      expect(scheduledRow!['delivery_status'], 'scheduled');
    });

    test('a scheduler failure is a visible per-reminder diagnostic', () async {
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
      );
      addTearDown(h.close);
      await _createAbsolute(
        h,
        seed: 'a',
        timezoneId: 'Etc/UTC',
        local: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(9, 0)),
      );
      h.transport.failReminderIds.add(h.rid('a').value);

      final ReconciliationOutcome outcome = await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );
      expect(
        outcome.diagnostics.any(
          (ReminderDiagnostic d) =>
              d.code == ReminderDiagnosticCode.schedulerFailure,
        ),
        isTrue,
      );
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT delivery_status FROM reminders WHERE id = ?',
        <Object?>[h.rid('a').value],
      );
      expect(row!['delivery_status'], 'failed');
    });
  });

  group('given quiet hours', () {
    test('defers a fire inside the window to the resume instant', () async {
      final NotificationSettings settings = NotificationSettings.defaults()
          .copyWith(
            quietHours: QuietHours(
              enabled: true,
              start: LocalTime(22, 0),
              end: LocalTime(7, 0),
            ),
          );
      final ReminderHarness h = await ReminderHarness.open(
        initialUtc: DateTime.utc(2024, 6, 28, 12),
        settingsStore: _FixedSettings(settings),
      );
      addTearDown(h.close);
      // 23:30 UTC lands inside quiet hours -> deferred to 07:00 next day.
      await _createAbsolute(
        h,
        seed: 'a',
        timezoneId: 'Etc/UTC',
        local: LocalDateTime(LocalDate(2024, 6, 30), LocalTime(23, 30)),
      );

      await h.service.reconcile(
        h.profileId.value,
        ReconciliationTrigger.launch,
      );
      final List<ScheduledNotification> pending = await h.transport.pending();
      expect(
        pending.single.fireAtUtc,
        DateTime.utc(2024, 7, 1, 7).microsecondsSinceEpoch,
      );
    });
  });

  group('given contextual permission (R-NOTIFY-002)', () {
    test(
      'requests with a pre-permission explanation only when undetermined',
      () async {
        final ReminderHarness h = await ReminderHarness.open(
          capability: const SchedulerCapability(
            permission: PermissionStatus.notDetermined,
            available: true,
            exactAlarms: true,
            actionsSupported: true,
          ),
        );
        addTearDown(h.close);
        h.transport.grantOnRequest(PermissionStatus.granted);

        final PermissionOutcome outcome = await h.service
            .requestPermissionAfterEnable();
        expect(outcome.explanationShown, isTrue);
        expect(outcome.requested, isTrue);
        expect(outcome.status, PermissionStatus.granted);
        expect(h.transport.requestCount, 1);

        // Already granted: a second call does not re-prompt.
        final PermissionOutcome second = await h.service
            .requestPermissionAfterEnable();
        expect(second.requested, isFalse);
        expect(h.transport.requestCount, 1);
      },
    );
  });
}
