import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

int _micros(int day, int hour) =>
    DateTime.utc(2024, 6, day, hour).microsecondsSinceEpoch;

ResolvedReminder _r(String id, int day, int hour, {ReminderCategory? cat}) =>
    ResolvedReminder(
      reminderId: id,
      category: cat ?? ReminderCategory.task,
      fireAtUtc: _micros(day, hour),
    );

/// **Validates: Requirements R-NOTIFY-003, R-NOTIFY-004, R-NOTIFY-006**
void main() {
  final int now = _micros(1, 0);
  final int horizonEnd = _micros(15, 0);

  group('given the pure rolling-horizon reconciler', () {
    test('schedules only future reminders inside the horizon window', () {
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[
          _r('past', 1, -0), // equal to now -> excluded
          _r('soon', 2, 9),
          _r('beyond', 30, 9), // beyond horizon -> excluded
        ],
        currentlyScheduled: const <ScheduledEntry>[],
        settings: NotificationSettings.defaults(),
        capability: SchedulerCapability.fullyCapable(),
      );

      expect(plan.toSchedule.map((DesiredSchedule d) => d.reminderId), <String>[
        'soon',
      ]);
      expect(plan.toCancel, isEmpty);
    });

    test('drops everything and reports when permission is denied', () {
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[_r('a', 2, 9)],
        currentlyScheduled: <ScheduledEntry>[
          ScheduledEntry(reminderId: 'a', fireAtUtc: _micros(2, 9)),
        ],
        settings: NotificationSettings.defaults(),
        capability: const SchedulerCapability(
          permission: PermissionStatus.denied,
          available: true,
          exactAlarms: true,
          actionsSupported: true,
        ),
      );

      expect(plan.toSchedule, isEmpty);
      expect(plan.toCancel, <String>['a']);
      expect(
        plan.hasDiagnostic(ReminderDiagnosticCode.permissionDenied),
        isTrue,
      );
    });

    test('skips disabled categories and reports once per category', () {
      final NotificationSettings settings = NotificationSettings.defaults()
          .copyWith(
            categoryEnabled: <ReminderCategory, bool>{
              ReminderCategory.task: true,
              ReminderCategory.habit: false,
              ReminderCategory.study: true,
              ReminderCategory.deadline: true,
            },
          );
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[
          _r('t', 2, 9),
          _r('h1', 2, 10, cat: ReminderCategory.habit),
          _r('h2', 2, 11, cat: ReminderCategory.habit),
        ],
        currentlyScheduled: const <ScheduledEntry>[],
        settings: settings,
        capability: SchedulerCapability.fullyCapable(),
      );

      expect(plan.toSchedule.map((DesiredSchedule d) => d.reminderId), <String>[
        't',
      ]);
      expect(
        plan.diagnostics
            .where(
              (ReminderDiagnostic d) =>
                  d.code == ReminderDiagnosticCode.categoryDisabled,
            )
            .length,
        1,
      );
    });

    test('truncates to the earliest N under an OS quota and reports', () {
      final NotificationSettings settings = NotificationSettings.defaults()
          .copyWith(maxScheduled: 2);
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[
          _r('c', 4, 9),
          _r('a', 2, 9),
          _r('b', 3, 9),
        ],
        currentlyScheduled: const <ScheduledEntry>[],
        settings: settings,
        capability: SchedulerCapability.fullyCapable(),
      );

      expect(plan.toSchedule.map((DesiredSchedule d) => d.reminderId), <String>[
        'a',
        'b',
      ]);
      expect(
        plan.hasDiagnostic(ReminderDiagnosticCode.osQuotaExceeded),
        isTrue,
      );
    });

    test('emits a minimal diff: only changed/new schedule, stale cancel', () {
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[
          _r('keep', 2, 9),
          _r('moved', 5, 9),
          _r('new', 6, 9),
        ],
        currentlyScheduled: <ScheduledEntry>[
          ScheduledEntry(reminderId: 'keep', fireAtUtc: _micros(2, 9)),
          ScheduledEntry(reminderId: 'moved', fireAtUtc: _micros(4, 9)),
          ScheduledEntry(reminderId: 'gone', fireAtUtc: _micros(7, 9)),
        ],
        settings: NotificationSettings.defaults(),
        capability: SchedulerCapability.fullyCapable(),
      );

      expect(
        plan.toSchedule.map((DesiredSchedule d) => d.reminderId).toSet(),
        <String>{'moved', 'new'},
      );
      expect(plan.toCancel.toSet(), <String>{'moved', 'gone'});
    });

    test('surfaces exact-alarm and unsupported-action degradations', () {
      final ReconciliationPlan plan = HorizonReconciler.plan(
        nowUtc: now,
        horizonEndUtc: horizonEnd,
        resolved: <ResolvedReminder>[_r('a', 2, 9)],
        currentlyScheduled: const <ScheduledEntry>[],
        settings: NotificationSettings.defaults(),
        capability: const SchedulerCapability(
          permission: PermissionStatus.granted,
          available: true,
          exactAlarms: false,
          actionsSupported: false,
          evidenceId: 'PROBE-X',
        ),
      );

      expect(plan.toSchedule.length, 1);
      expect(
        plan.hasDiagnostic(ReminderDiagnosticCode.exactAlarmUnavailable),
        isTrue,
      );
      expect(
        plan.hasDiagnostic(ReminderDiagnosticCode.unsupportedActions),
        isTrue,
      );
    });
  });

  group('given cross-midnight quiet hours', () {
    LocalDateTime at(int day, int hour, int minute) =>
        LocalDateTime(LocalDate(2024, 6, day), LocalTime(hour, minute));

    test('defers a pre-midnight fire to the next-day resume time', () {
      final QuietHours quiet = QuietHours(
        enabled: true,
        start: LocalTime(22, 0),
        end: LocalTime(7, 0),
      );
      final LocalDateTime shifted = quiet.shift(at(1, 23, 30));
      expect(shifted, LocalDateTime(LocalDate(2024, 6, 2), LocalTime(7, 0)));
    });

    test('defers a post-midnight fire to the same-day resume time', () {
      final QuietHours quiet = QuietHours(
        enabled: true,
        start: LocalTime(22, 0),
        end: LocalTime(7, 0),
      );
      final LocalDateTime shifted = quiet.shift(at(2, 3, 15));
      expect(shifted, LocalDateTime(LocalDate(2024, 6, 2), LocalTime(7, 0)));
    });

    test('leaves a fire outside the window untouched', () {
      final QuietHours quiet = QuietHours(
        enabled: true,
        start: LocalTime(22, 0),
        end: LocalTime(7, 0),
      );
      final LocalDateTime fire = at(2, 9, 0);
      expect(quiet.shift(fire), fire);
    });

    test('handles a non-wrapping daytime window', () {
      final QuietHours quiet = QuietHours(
        enabled: true,
        start: LocalTime(9, 0),
        end: LocalTime(17, 0),
      );
      expect(
        quiet.shift(at(2, 12, 0)),
        LocalDateTime(LocalDate(2024, 6, 2), LocalTime(17, 0)),
      );
      expect(quiet.shift(at(2, 8, 0)), at(2, 8, 0));
    });
  });
}
