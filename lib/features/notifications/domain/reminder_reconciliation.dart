import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

/// What triggered a reconciliation pass (R-NOTIFY-004). Recorded for
/// diagnostics and to make lifecycle behavior explicit and testable.
enum ReconciliationTrigger {
  launch,
  resume,
  timezoneChange,
  permissionChange,
  dataChange,
}

/// A reminder resolved to a concrete absolute fire instant, ready to be diffed
/// against the OS scheduler's current set. Quiet-hours shifting and timezone
/// resolution have already been applied to [fireAtUtc] by the service.
final class ResolvedReminder {
  const ResolvedReminder({
    required this.reminderId,
    required this.category,
    required this.fireAtUtc,
  });

  final String reminderId;
  final ReminderCategory category;
  final int fireAtUtc;
}

/// One reminder that should be present in the OS scheduler after this pass.
final class DesiredSchedule {
  const DesiredSchedule({
    required this.reminderId,
    required this.category,
    required this.fireAtUtc,
  });

  final String reminderId;
  final ReminderCategory category;
  final int fireAtUtc;

  @override
  bool operator ==(Object other) =>
      other is DesiredSchedule &&
      other.reminderId == reminderId &&
      other.fireAtUtc == fireAtUtc;

  @override
  int get hashCode => Object.hash(reminderId, fireAtUtc);
}

/// An entry already placed with the OS scheduler (as reported by the
/// transport), used to compute a minimal schedule/cancel diff.
final class ScheduledEntry {
  const ScheduledEntry({required this.reminderId, required this.fireAtUtc});

  final String reminderId;
  final int fireAtUtc;
}

/// The deterministic output of a reconciliation pass.
final class ReconciliationPlan {
  const ReconciliationPlan({
    required this.toSchedule,
    required this.toCancel,
    required this.diagnostics,
  });

  /// Reminders to (re)place with the OS scheduler, ordered by fire time.
  final List<DesiredSchedule> toSchedule;

  /// Reminder ids to cancel from the OS scheduler.
  final List<String> toCancel;

  /// Visible diagnostics for this pass (R-NOTIFY-003).
  final List<ReminderDiagnostic> diagnostics;

  bool hasDiagnostic(ReminderDiagnosticCode code) =>
      diagnostics.any((ReminderDiagnostic d) => d.code == code);
}

/// The pure rolling-horizon reconciliation policy (R-NOTIFY-004).
///
/// Given the resolved reminder set, the current OS-scheduler contents, the
/// active settings, and the platform capability, it computes a deterministic
/// minimal set of schedule/cancel operations plus the visible diagnostics. It
/// performs no I/O and no timezone math (the service resolves instants and
/// applies quiet hours first), so its behavior is fully unit-testable and
/// identical on every device and run.
abstract final class HorizonReconciler {
  static ReconciliationPlan plan({
    required int nowUtc,
    required int horizonEndUtc,
    required List<ResolvedReminder> resolved,
    required List<ScheduledEntry> currentlyScheduled,
    required NotificationSettings settings,
    required SchedulerCapability capability,
    String? evidenceId,
  }) {
    final List<ReminderDiagnostic> diagnostics = <ReminderDiagnostic>[];

    // No scheduler at all: cancel everything and report honestly.
    if (!capability.available) {
      diagnostics.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.schedulerUnavailable,
          evidenceId: capability.evidenceId ?? evidenceId,
          detail: 'No notification scheduler on this platform.',
        ),
      );
      return ReconciliationPlan(
        toSchedule: const <DesiredSchedule>[],
        toCancel: currentlyScheduled
            .map((ScheduledEntry e) => e.reminderId)
            .toList(growable: false),
        diagnostics: diagnostics,
      );
    }

    // Permission not granted: nothing may be scheduled; drop existing.
    if (!capability.permission.isGranted) {
      diagnostics.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.permissionDenied,
          evidenceId: capability.evidenceId ?? evidenceId,
          detail:
              'Notification permission is '
              '${capability.permission.name}.',
        ),
      );
      return ReconciliationPlan(
        toSchedule: const <DesiredSchedule>[],
        toCancel: currentlyScheduled
            .map((ScheduledEntry e) => e.reminderId)
            .toList(growable: false),
        diagnostics: diagnostics,
      );
    }

    // Capability degradations that do not block scheduling but are visible.
    if (!capability.exactAlarms) {
      diagnostics.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.exactAlarmUnavailable,
          evidenceId: capability.evidenceId ?? evidenceId,
          detail: 'Exact alarms unavailable; reminders may fire inexactly.',
        ),
      );
    }
    if (!capability.actionsSupported) {
      diagnostics.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.unsupportedActions,
          evidenceId: capability.evidenceId ?? evidenceId,
          detail: 'Interactive notification actions are not supported.',
        ),
      );
    }

    // Category filtering + horizon windowing.
    final Set<ReminderCategory> disabledSeen = <ReminderCategory>{};
    final List<ResolvedReminder> eligible = <ResolvedReminder>[];
    for (final ResolvedReminder r in resolved) {
      if (!settings.isCategoryEnabled(r.category)) {
        if (disabledSeen.add(r.category)) {
          diagnostics.add(
            ReminderDiagnostic(
              code: ReminderDiagnosticCode.categoryDisabled,
              detail: 'Category ${r.category.name} is disabled.',
            ),
          );
        }
        continue;
      }
      // Rolling horizon: only place reminders that fire strictly in the future
      // and within the horizon window. Past-due instants are handled by
      // delivery, not future scheduling.
      if (r.fireAtUtc <= nowUtc || r.fireAtUtc > horizonEndUtc) {
        continue;
      }
      eligible.add(r);
    }

    // Deterministic ordering by fire time then id.
    eligible.sort((ResolvedReminder a, ResolvedReminder b) {
      final int byTime = a.fireAtUtc.compareTo(b.fireAtUtc);
      return byTime != 0 ? byTime : a.reminderId.compareTo(b.reminderId);
    });

    // Effective quota is the tighter of the settings budget and any platform
    // pending-request quota.
    final int quota = capability.pendingQuota == null
        ? settings.maxScheduled
        : (settings.maxScheduled < capability.pendingQuota!
              ? settings.maxScheduled
              : capability.pendingQuota!);

    List<ResolvedReminder> desiredList = eligible;
    if (eligible.length > quota) {
      desiredList = eligible.sublist(0, quota);
      diagnostics.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.osQuotaExceeded,
          evidenceId: capability.evidenceId ?? evidenceId,
          detail:
              'Scheduling budget $quota exceeded by ${eligible.length} '
              'due reminders; horizon truncated to the earliest $quota.',
        ),
      );
    }

    final Map<String, DesiredSchedule> desired = <String, DesiredSchedule>{
      for (final ResolvedReminder r in desiredList)
        r.reminderId: DesiredSchedule(
          reminderId: r.reminderId,
          category: r.category,
          fireAtUtc: r.fireAtUtc,
        ),
    };
    final Map<String, int> current = <String, int>{
      for (final ScheduledEntry e in currentlyScheduled)
        e.reminderId: e.fireAtUtc,
    };

    // Minimal diff: schedule new/changed, cancel removed/changed.
    final List<DesiredSchedule> toSchedule = <DesiredSchedule>[];
    for (final DesiredSchedule d in desired.values) {
      final int? existing = current[d.reminderId];
      if (existing == null || existing != d.fireAtUtc) {
        toSchedule.add(d);
      }
    }
    toSchedule.sort(
      (DesiredSchedule a, DesiredSchedule b) =>
          a.fireAtUtc.compareTo(b.fireAtUtc),
    );

    final List<String> toCancel = <String>[];
    for (final MapEntry<String, int> e in current.entries) {
      final DesiredSchedule? d = desired[e.key];
      if (d == null || d.fireAtUtc != e.value) {
        toCancel.add(e.key);
      }
    }
    toCancel.sort();

    return ReconciliationPlan(
      toSchedule: toSchedule,
      toCancel: toCancel,
      diagnostics: diagnostics,
    );
  }
}
