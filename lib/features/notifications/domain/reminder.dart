import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';

/// The kind of aggregate a reminder is attached to (R-NOTIFY-001).
///
/// MVP entity types present are tasks; `habit`, `study`, and `deadline` are
/// modelled from the MVP so the one scheduling service extends to those
/// aggregates without a second scheduling code path. `workout` is added in V1
/// once the fitness feature exists (R-NOTIFY-001 "V1 adds workout reminders
/// when fitness exists").
enum ReminderOwnerType {
  task,
  habit,
  study,
  deadline,
  workout;

  String get wire => name;

  static ReminderOwnerType fromWire(String value) => values.firstWhere(
    (ReminderOwnerType e) => e.name == value,
    orElse: () => throw FormatException('Unknown reminder owner type: $value'),
  );
}

/// Per-category channel used for quiet-hours and per-category settings
/// (R-NOTIFY-006). Categories align with owner types but are a distinct axis so
/// a user can silence, say, workout prompts without touching deadline
/// reminders.
enum ReminderCategory {
  task,
  habit,
  study,
  deadline,
  workout;

  String get wire => name;

  static ReminderCategory fromWire(String value) => values.firstWhere(
    (ReminderCategory e) => e.name == value,
    orElse: () => throw FormatException('Unknown reminder category: $value'),
  );

  static ReminderCategory forOwner(ReminderOwnerType owner) => switch (owner) {
    ReminderOwnerType.task => ReminderCategory.task,
    ReminderOwnerType.habit => ReminderCategory.habit,
    ReminderOwnerType.study => ReminderCategory.study,
    ReminderOwnerType.deadline => ReminderCategory.deadline,
    ReminderOwnerType.workout => ReminderCategory.workout,
  };
}

/// The visible delivery state of a reminder, surfaced in reminder details
/// (R-NOTIFY-003).
enum ReminderDeliveryStatus {
  /// Not yet placed with the OS scheduler (outside the horizon or awaiting
  /// reconciliation).
  pending,

  /// Placed with the OS scheduler for a concrete future instant.
  scheduled,

  /// Deliberately not scheduled (category disabled, permission denied, quota).
  skipped,

  /// The scheduler rejected the request or the platform lacks the capability.
  failed;

  String get wire => name;

  static ReminderDeliveryStatus fromWire(String value) => values.firstWhere(
    (ReminderDeliveryStatus e) => e.name == value,
    orElse: () =>
        throw FormatException('Unknown reminder delivery status: $value'),
  );
}

/// How a reminder's fire time is derived (data-model §3 "trigger kind").
enum ReminderTriggerKind { absolute, offset }

/// A reminder trigger. A reminder fires at *either* a fixed wall-clock local
/// time in a preserved IANA timezone ([AbsoluteLocalTrigger]) *or* a signed
/// minute offset relative to its owner's due instant ([OffsetTrigger]), never
/// both (R-GEN-004, data-model §3).
sealed class ReminderTrigger {
  const ReminderTrigger();

  ReminderTriggerKind get kind;
}

/// Fires at a wall-clock [local] time interpreted in the reminder's preserved
/// IANA timezone. The instant is resolved deterministically through a
/// [TimeZoneResolver] using the reminder's DST policy so travel never silently
/// moves the reminder and DST gaps/overlaps resolve the same way on every
/// device (R-GEN-004).
final class AbsoluteLocalTrigger extends ReminderTrigger {
  const AbsoluteLocalTrigger({required this.local});

  final LocalDateTime local;

  @override
  ReminderTriggerKind get kind => ReminderTriggerKind.absolute;
}

/// Fires [offsetMinutes] before the owner's due instant (a positive value means
/// "N minutes before due"). Resolved against an anchor instant supplied at
/// reconciliation time from the owning aggregate.
final class OffsetTrigger extends ReminderTrigger {
  const OffsetTrigger({required this.offsetMinutes});

  final int offsetMinutes;

  @override
  ReminderTriggerKind get kind => ReminderTriggerKind.offset;
}

/// An immutable reminder model shared by every MVP aggregate type
/// (R-NOTIFY-001). Persistence maps this explicitly to the `reminders` table
/// behind the infrastructure boundary.
final class Reminder {
  const Reminder({
    required this.id,
    required this.profileId,
    required this.ownerType,
    required this.ownerId,
    required this.category,
    required this.trigger,
    required this.timezoneId,
    required this.enabled,
    required this.deliveryStatus,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.dstPolicy = DstPolicy.forwardGapEarlierOverlap,
    this.nextFireAtUtc,
    this.snoozedUntilUtc,
    this.token,
    this.lastDiagnosticCode,
    this.revision = 1,
    this.deletedAtUtc,
  });

  final ReminderId id;
  final ProfileId profileId;
  final ReminderOwnerType ownerType;
  final String ownerId;
  final ReminderCategory category;
  final ReminderTrigger trigger;

  /// The preserved IANA timezone used to resolve the trigger and to interpret
  /// quiet hours for this reminder (R-GEN-004, R-NOTIFY-006).
  final String timezoneId;

  /// The deterministic DST policy for wall-clock resolution.
  final DstPolicy dstPolicy;

  final bool enabled;
  final ReminderDeliveryStatus deliveryStatus;

  /// The cached absolute instant the reminder is currently scheduled for, or
  /// null when it is not scheduled. Recomputed each reconciliation.
  final int? nextFireAtUtc;

  /// A one-shot snooze instant (UTC micros) that overrides the trigger until it
  /// passes (R-NOTIFY-005). Null when not snoozed.
  final int? snoozedUntilUtc;

  /// The opaque OS scheduler token, or null when not placed. Local-only
  /// (never replicated) per data-model §3.
  final String? token;

  /// The most recent diagnostic that affected delivery, surfaced in reminder
  /// details (R-NOTIFY-003).
  final String? lastDiagnosticCode;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  Reminder copyWith({
    bool? enabled,
    ReminderDeliveryStatus? deliveryStatus,
    Object? nextFireAtUtc = _sentinel,
    Object? snoozedUntilUtc = _sentinel,
    Object? token = _sentinel,
    Object? lastDiagnosticCode = _sentinel,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) => Reminder(
    id: id,
    profileId: profileId,
    ownerType: ownerType,
    ownerId: ownerId,
    category: category,
    trigger: trigger,
    timezoneId: timezoneId,
    dstPolicy: dstPolicy,
    enabled: enabled ?? this.enabled,
    deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    nextFireAtUtc: identical(nextFireAtUtc, _sentinel)
        ? this.nextFireAtUtc
        : nextFireAtUtc as int?,
    snoozedUntilUtc: identical(snoozedUntilUtc, _sentinel)
        ? this.snoozedUntilUtc
        : snoozedUntilUtc as int?,
    token: identical(token, _sentinel) ? this.token : token as String?,
    lastDiagnosticCode: identical(lastDiagnosticCode, _sentinel)
        ? this.lastDiagnosticCode
        : lastDiagnosticCode as String?,
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: identical(deletedAtUtc, _sentinel)
        ? this.deletedAtUtc
        : deletedAtUtc as int?,
  );

  static const Object _sentinel = Object();
}
