import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

/// Maps between the `reminders` Drift row and the [Reminder] domain model.
///
/// All enum ↔ string conversions are explicit and unknown-safe so a corrupt or
/// forward-version row is rejected loudly rather than silently mis-decoded.
abstract final class ReminderMapper {
  static const String forwardPolicyWire = 'forward_gap_earlier_overlap';
  static const String backwardPolicyWire = 'backward_gap_later_overlap';

  static Reminder fromRow(ReminderRow row) {
    final ReminderTriggerKind kind = switch (row.triggerKind) {
      'absolute' => ReminderTriggerKind.absolute,
      'offset' => ReminderTriggerKind.offset,
      _ => throw FormatException('Unknown trigger kind: ${row.triggerKind}'),
    };
    final ReminderTrigger trigger = switch (kind) {
      ReminderTriggerKind.absolute => AbsoluteLocalTrigger(
        local: _parseLocal(row.absoluteLocal!),
      ),
      ReminderTriggerKind.offset => OffsetTrigger(
        offsetMinutes: row.offsetMinutes!,
      ),
    };
    return Reminder(
      id: ReminderId(row.id),
      profileId: ProfileId(row.profileId),
      ownerType: ReminderOwnerType.fromWire(row.ownerType),
      ownerId: row.ownerId,
      category: ReminderCategory.fromWire(row.category),
      trigger: trigger,
      timezoneId: row.timezoneId,
      dstPolicy: dstPolicyFromWire(row.dstPolicy),
      enabled: row.enabled,
      deliveryStatus: ReminderDeliveryStatus.fromWire(row.deliveryStatus),
      nextFireAtUtc: row.nextFireAtUtc,
      snoozedUntilUtc: row.snoozedUntilUtc,
      token: row.token,
      lastDiagnosticCode: row.lastDiagnosticCode,
      revision: row.revision,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      deletedAtUtc: row.deletedAtUtc,
    );
  }

  static RemindersCompanion toInsert(Reminder reminder) {
    final ReminderTrigger trigger = reminder.trigger;
    return RemindersCompanion.insert(
      id: reminder.id.value,
      profileId: reminder.profileId.value,
      ownerType: reminder.ownerType.wire,
      ownerId: reminder.ownerId,
      category: reminder.category.wire,
      triggerKind: trigger.kind.name,
      absoluteLocal: Value<String?>(
        trigger is AbsoluteLocalTrigger ? trigger.local.iso : null,
      ),
      offsetMinutes: Value<int?>(
        trigger is OffsetTrigger ? trigger.offsetMinutes : null,
      ),
      timezoneId: reminder.timezoneId,
      dstPolicy: dstPolicyWire(reminder.dstPolicy),
      enabled: Value<bool>(reminder.enabled),
      nextFireAtUtc: Value<int?>(reminder.nextFireAtUtc),
      snoozedUntilUtc: Value<int?>(reminder.snoozedUntilUtc),
      token: Value<String?>(reminder.token),
      deliveryStatus: reminder.deliveryStatus.wire,
      lastDiagnosticCode: Value<String?>(reminder.lastDiagnosticCode),
      revision: Value<int>(reminder.revision),
      createdAtUtc: reminder.createdAtUtc,
      updatedAtUtc: reminder.updatedAtUtc,
      deletedAtUtc: Value<int?>(reminder.deletedAtUtc),
    );
  }

  static RemindersCompanion toUpdate(Reminder reminder) {
    final ReminderTrigger trigger = reminder.trigger;
    return RemindersCompanion(
      ownerType: Value<String>(reminder.ownerType.wire),
      ownerId: Value<String>(reminder.ownerId),
      category: Value<String>(reminder.category.wire),
      triggerKind: Value<String>(trigger.kind.name),
      absoluteLocal: Value<String?>(
        trigger is AbsoluteLocalTrigger ? trigger.local.iso : null,
      ),
      offsetMinutes: Value<int?>(
        trigger is OffsetTrigger ? trigger.offsetMinutes : null,
      ),
      timezoneId: Value<String>(reminder.timezoneId),
      dstPolicy: Value<String>(dstPolicyWire(reminder.dstPolicy)),
      enabled: Value<bool>(reminder.enabled),
      nextFireAtUtc: Value<int?>(reminder.nextFireAtUtc),
      snoozedUntilUtc: Value<int?>(reminder.snoozedUntilUtc),
      token: Value<String?>(reminder.token),
      deliveryStatus: Value<String>(reminder.deliveryStatus.wire),
      lastDiagnosticCode: Value<String?>(reminder.lastDiagnosticCode),
      revision: Value<int>(reminder.revision),
      updatedAtUtc: Value<int>(reminder.updatedAtUtc),
      deletedAtUtc: Value<int?>(reminder.deletedAtUtc),
    );
  }

  static String dstPolicyWire(DstPolicy policy) => switch (policy) {
    DstPolicy.forwardGapEarlierOverlap => forwardPolicyWire,
    DstPolicy.backwardGapLaterOverlap => backwardPolicyWire,
  };

  static DstPolicy dstPolicyFromWire(String wire) => switch (wire) {
    forwardPolicyWire => DstPolicy.forwardGapEarlierOverlap,
    backwardPolicyWire => DstPolicy.backwardGapLaterOverlap,
    _ => throw FormatException('Unknown DST policy: $wire'),
  };

  static LocalDateTime _parseLocal(String iso) {
    final List<String> parts = iso.split('T');
    if (parts.length != 2) {
      throw FormatException('Expected ISO local date-time: $iso');
    }
    return LocalDateTime(LocalDate.parse(parts[0]), LocalTime.parse(parts[1]));
  }
}
