import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

/// Input for creating a reminder (R-NOTIFY-001). Exactly one of
/// [absoluteLocal] / [offsetMinutes] must be provided, matching [triggerKind].
final class CreateReminderInput {
  const CreateReminderInput({
    required this.ownerType,
    required this.ownerId,
    required this.triggerKind,
    required this.timezoneId,
    this.category,
    this.absoluteLocal,
    this.offsetMinutes,
    this.dstPolicy = DstPolicy.forwardGapEarlierOverlap,
    this.enabled = true,
  });

  final ReminderOwnerType ownerType;
  final String ownerId;
  final ReminderTriggerKind triggerKind;
  final String timezoneId;

  /// Defaults to the category matching [ownerType] when null.
  final ReminderCategory? category;
  final LocalDateTime? absoluteLocal;
  final int? offsetMinutes;
  final DstPolicy dstPolicy;
  final bool enabled;
}

/// The kind of committed notification action (R-NOTIFY-005).
enum ReminderActionKind { complete, snooze, dismiss }

/// An idempotent notification action to persist before the notification is
/// dismissed (R-NOTIFY-005, R-GEN-005).
final class ReminderAction {
  const ReminderAction._(this.kind, {this.snoozeMinutes});

  /// Marks the reminder acknowledged/dismissed.
  factory ReminderAction.dismiss() =>
      const ReminderAction._(ReminderActionKind.dismiss);

  /// Defers the reminder by [minutes] from the action instant.
  factory ReminderAction.snooze(int minutes) {
    if (minutes <= 0) {
      throw ArgumentError.value(minutes, 'minutes', 'Must be positive.');
    }
    return ReminderAction._(ReminderActionKind.snooze, snoozeMinutes: minutes);
  }

  /// Marks the reminder's owner complete (delegated to the owner feature).
  factory ReminderAction.complete() =>
      const ReminderAction._(ReminderActionKind.complete);

  final ReminderActionKind kind;
  final int? snoozeMinutes;

  String get wire => kind.name;
}
