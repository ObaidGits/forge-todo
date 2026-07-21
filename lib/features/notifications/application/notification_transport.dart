import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

/// A single OS-level scheduled notification request. Time is always UTC so the
/// transport never re-interprets wall-clock intent (R-GEN-004).
final class ScheduledNotification {
  const ScheduledNotification({
    required this.reminderId,
    required this.fireAtUtc,
    required this.category,
    required this.wantsActions,
  });

  final String reminderId;

  /// The absolute instant the OS should deliver the notification (UTC micros).
  final int fireAtUtc;
  final ReminderCategory category;

  /// Whether this notification requests interactive actions (complete/snooze).
  final bool wantsActions;
}

/// Thrown by a transport when the OS scheduler rejects a request. Kept behind
/// the port so the scheduling service maps it to a diagnostic rather than
/// leaking a plugin exception (design §9).
final class NotificationTransportException implements Exception {
  const NotificationTransportException(this.message);
  final String message;

  @override
  String toString() => 'NotificationTransportException: $message';
}

/// The low-level OS notification/background-scheduling port (design §2/§9).
///
/// This is the single seam between the reminder scheduling service and the
/// real platform plugin. It is fully replaceable and is exercised in tests by
/// a fake, so no reminder logic depends on a real plugin.
abstract interface class NotificationTransport {
  /// The current capability snapshot, including live permission state.
  Future<SchedulerCapability> capability();

  /// Contextually requests notification permission with a pre-permission
  /// explanation where the platform allows it (R-NOTIFY-002). Returns the
  /// resulting permission status.
  Future<PermissionStatus> requestPermission();

  /// The reminder ids currently placed with the OS scheduler and their fire
  /// instants, used to compute a minimal reconciliation diff.
  Future<List<ScheduledNotification>> pending();

  /// Places or replaces a single notification. Throws
  /// [NotificationTransportException] on scheduler failure.
  Future<void> schedule(ScheduledNotification notification);

  /// Cancels a scheduled notification by reminder id. Idempotent: cancelling an
  /// absent id is a no-op returning false.
  Future<bool> cancel(String reminderId);
}
