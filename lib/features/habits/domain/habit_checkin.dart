/// The kind of an append-only habit check-in observation (R-HABIT-002,
/// R-HABIT-003, R-HABIT-005).
///
/// Check-ins are append-only and auditable. A correction never rewrites a prior
/// observation; it appends a superseding record (`is_current = 1`) that points
/// at the observation it supersedes, and the superseded record remains in the
/// log. The current projection derives from all non-superseded observations.
enum HabitCheckinKind {
  /// An explicit true check-in that completes a boolean target.
  booleanTrue('true'),

  /// A numeric observation contributing to a count/duration/quantity total.
  value('value'),

  /// An explicit violation of an abstinence target.
  violation('violation'),

  /// A superseding correction of a prior observation or violation.
  correct('correct');

  const HabitCheckinKind(this.wire);

  final String wire;

  static HabitCheckinKind fromWire(String wire) {
    for (final HabitCheckinKind kind in HabitCheckinKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown habit check-in kind: $wire');
  }
}

/// A non-superseded (current) observation used by the projection policy.
///
/// Only current observations (`is_current = 1`) participate in the projection;
/// superseded records stay in the audit log but are not passed here. A
/// [normalizedValue] is the canonical integer amount already converted to the
/// bound target's unit/dimension for numeric kinds (R-HABIT-003).
final class HabitObservation {
  const HabitObservation({
    required this.kind,
    this.normalizedValue = 0,
    this.booleanValue = false,
  });

  /// A boolean true observation.
  const HabitObservation.booleanTrue()
    : kind = HabitCheckinKind.booleanTrue,
      normalizedValue = 0,
      booleanValue = true;

  /// A numeric observation already normalized to canonical units.
  const HabitObservation.value(this.normalizedValue)
    : kind = HabitCheckinKind.value,
      booleanValue = false;

  /// An abstinence violation observation.
  const HabitObservation.violation()
    : kind = HabitCheckinKind.violation,
      normalizedValue = 0,
      booleanValue = false;

  final HabitCheckinKind kind;
  final int normalizedValue;
  final bool booleanValue;
}
