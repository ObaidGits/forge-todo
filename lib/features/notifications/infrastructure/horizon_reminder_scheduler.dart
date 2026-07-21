import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_scheduler.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

/// A [ReminderScheduler] that reconciles the desired horizon against a
/// [NotificationTransport] using the pure [HorizonReconciler] (design §9,
/// R-NOTIFY-004).
///
/// It reads the transport's current capability and pending set, asks the pure
/// policy for a minimal schedule/cancel diff, applies it through the transport,
/// and maps any transport failure to a visible [ReminderDiagnostic] instead of
/// leaking a plugin exception (R-NOTIFY-003).
final class HorizonReminderScheduler implements ReminderScheduler {
  const HorizonReminderScheduler(this._transport);

  final NotificationTransport _transport;

  @override
  Future<ScheduleReport> reconcile(ReminderHorizon horizon) async {
    final SchedulerCapability capability = await _transport.capability();
    final List<ScheduledNotification> pending = await _transport.pending();
    final List<ScheduledEntry> current = pending
        .map(
          (ScheduledNotification n) =>
              ScheduledEntry(reminderId: n.reminderId, fireAtUtc: n.fireAtUtc),
        )
        .toList(growable: false);

    final ReconciliationPlan plan = HorizonReconciler.plan(
      nowUtc: horizon.nowUtc,
      horizonEndUtc: horizon.horizonEndUtc,
      resolved: horizon.resolved,
      currentlyScheduled: current,
      settings: horizon.settings,
      capability: capability,
      evidenceId: capability.evidenceId,
    );

    final Map<String, int> placed = <String, int>{
      for (final ScheduledEntry e in current) e.reminderId: e.fireAtUtc,
    };
    final List<ReminderDiagnostic> diagnostics = <ReminderDiagnostic>[
      ...plan.diagnostics,
    ];

    int cancelled = 0;
    for (final String id in plan.toCancel) {
      final bool removed = await _transport.cancel(id);
      placed.remove(id);
      if (removed) {
        cancelled += 1;
      }
    }

    int scheduled = 0;
    for (final DesiredSchedule d in plan.toSchedule) {
      try {
        await _transport.schedule(
          ScheduledNotification(
            reminderId: d.reminderId,
            fireAtUtc: d.fireAtUtc,
            category: d.category,
            wantsActions: capability.actionsSupported,
          ),
        );
        placed[d.reminderId] = d.fireAtUtc;
        scheduled += 1;
      } on NotificationTransportException catch (error) {
        diagnostics.add(
          ReminderDiagnostic(
            code: ReminderDiagnosticCode.schedulerFailure,
            reminderId: d.reminderId,
            detail: error.message,
          ),
        );
      }
    }

    return ScheduleReport(
      scheduledCount: scheduled,
      cancelledCount: cancelled,
      diagnostics: diagnostics,
      placed: placed,
    );
  }
}

/// A small helper mapping an owner type to its default reminder category.
ReminderCategory categoryForOwner(ReminderOwnerType owner) =>
    ReminderCategory.forOwner(owner);
