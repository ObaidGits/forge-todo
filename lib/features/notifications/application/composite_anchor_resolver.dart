import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

/// Routes an [OffsetTrigger] anchor lookup to the per-owner-type resolver that
/// owns the aggregate (R-NOTIFY-001, R-NOTIFY-004).
///
/// The unified reminder scheduling service resolves offset reminders against an
/// anchor instant supplied by the owning aggregate. Each owner type (task,
/// habit, study, deadline/focus) exposes its own anchor source; this composite
/// dispatches by [ReminderOwnerType] so the one scheduling service extends to
/// habits, study, and focus without a second scheduling code path. An owner
/// type with no registered resolver yields a null anchor, so its offset
/// reminders are simply not scheduled this pass rather than erroring — exactly
/// how the service already treats a task with no due instant.
final class CompositeReminderAnchorResolver implements ReminderAnchorResolver {
  const CompositeReminderAnchorResolver(this._byOwner);

  /// Per-owner-type anchor resolvers. A missing entry means the owner type has
  /// no anchor source wired yet.
  final Map<ReminderOwnerType, ReminderAnchorResolver> _byOwner;

  /// Builds a composite from optional per-owner resolvers. Only the owner types
  /// with a non-null resolver are registered.
  factory CompositeReminderAnchorResolver.of({
    ReminderAnchorResolver? task,
    ReminderAnchorResolver? habit,
    ReminderAnchorResolver? study,
    ReminderAnchorResolver? deadline,
  }) {
    final Map<ReminderOwnerType, ReminderAnchorResolver> byOwner =
        <ReminderOwnerType, ReminderAnchorResolver>{};
    if (task != null) {
      byOwner[ReminderOwnerType.task] = task;
    }
    if (habit != null) {
      byOwner[ReminderOwnerType.habit] = habit;
    }
    if (study != null) {
      byOwner[ReminderOwnerType.study] = study;
    }
    if (deadline != null) {
      byOwner[ReminderOwnerType.deadline] = deadline;
    }
    return CompositeReminderAnchorResolver(byOwner);
  }

  @override
  Future<int?> anchorUtc({
    required String profileId,
    required ReminderOwnerType ownerType,
    required String ownerId,
  }) async {
    final ReminderAnchorResolver? resolver = _byOwner[ownerType];
    if (resolver == null) {
      return null;
    }
    return resolver.anchorUtc(
      profileId: profileId,
      ownerType: ownerType,
      ownerId: ownerId,
    );
  }
}
