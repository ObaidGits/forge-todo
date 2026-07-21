import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';

/// The desired rolling-horizon reminder set for one reconciliation pass
/// (design §9, R-NOTIFY-004). Instants are already resolved (timezone + quiet
/// hours applied) by the scheduling service.
final class ReminderHorizon {
  const ReminderHorizon({
    required this.nowUtc,
    required this.horizonEndUtc,
    required this.resolved,
    required this.settings,
    required this.trigger,
  });

  final int nowUtc;
  final int horizonEndUtc;
  final List<ResolvedReminder> resolved;
  final NotificationSettings settings;
  final ReconciliationTrigger trigger;
}

/// The committed result of a reconciliation pass (design §9). Callers surface
/// [diagnostics] in reminder details (R-NOTIFY-003).
final class ScheduleReport {
  const ScheduleReport({
    required this.scheduledCount,
    required this.cancelledCount,
    required this.diagnostics,
    required this.placed,
  });

  final int scheduledCount;
  final int cancelledCount;
  final List<ReminderDiagnostic> diagnostics;

  /// The reminders now placed with the OS scheduler, keyed by id → fire instant.
  final Map<String, int> placed;

  bool hasDiagnostic(ReminderDiagnosticCode code) =>
      diagnostics.any((ReminderDiagnostic d) => d.code == code);
}

/// The service port that reconciles a rolling reminder horizon with the OS
/// scheduler (design §9). Presence of this port does not promote a real plugin
/// into the build; the production adapter is assembled at the composition root.
abstract interface class ReminderScheduler {
  Future<ScheduleReport> reconcile(ReminderHorizon horizon);
}

/// A bounded background-scheduling capability (design §9). Configuring returns
/// what the platform will actually honor, never a promise of guaranteed
/// execution (non-goal in the spec).
enum BackgroundCapability { available, unavailable, permissionDenied }

/// The bounded background-callback port (design §9). Used to opportunistically
/// re-run reconciliation; correctness never depends on it firing.
abstract interface class BackgroundScheduler {
  Future<BackgroundCapability> configure();
}
