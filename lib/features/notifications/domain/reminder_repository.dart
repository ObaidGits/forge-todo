import 'package:forge/features/notifications/domain/reminder.dart';

/// Read access to the durable reminder model (R-NOTIFY-001). The concrete Drift
/// implementation lives behind the infrastructure boundary; the scheduling
/// service depends only on this port.
abstract interface class ReminderReadRepository {
  /// Every enabled, non-deleted reminder for [profileId], ordered stably by id.
  Future<List<Reminder>> enabledReminders(String profileId);

  /// A single reminder by id, or null when it does not exist for [profileId].
  Future<Reminder?> find(String profileId, String reminderId);

  /// Every non-deleted reminder attached to a given owner, used by owner
  /// screens to render reminder details and diagnostics (R-NOTIFY-003).
  Future<List<Reminder>> forOwner(
    String profileId, {
    required String ownerType,
    required String ownerId,
  });
}
