/// Habit target semantics and their authoritative per-version configuration
/// (R-HABIT-002, R-HABIT-003).
///
/// A habit schedule version pins exactly one [HabitTarget]. The target kind
/// fixes what a check-in means and how the current projection is derived; each
/// kind carries strict, self-validating invariants so an illegal target cannot
/// exist in the domain:
///
/// * `boolean`     completes on an explicit true check-in; no target/unit.
/// * `count`       sums non-superseded count observations toward a positive
///                 integer `target_value`; no custom unit.
/// * `duration`    sums canonical integer seconds toward a positive target
///                 while preserving the entered display unit.
/// * `quantity`    sums values only after compatible-unit normalization toward
///                 a positive target; a unit is required.
/// * `abstinence`  has no target value/unit; records explicit violations and
///                 completes only when its period closes with no violation.
///
/// For every aggregate schedule the version's [targetValue] under [kind] is the
/// sole authoritative target; no duplicate `weekly_count` target is stored
/// (R-HABIT-001).
library;

/// The versioned target semantics of a habit (R-HABIT-002).
enum HabitTargetKind {
  boolean('boolean'),
  count('count'),
  duration('duration'),
  quantity('quantity'),
  abstinence('abstinence');

  const HabitTargetKind(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Whether the kind accumulates a numeric total toward [HabitTarget.targetValue].
  bool get isNumeric =>
      this == HabitTargetKind.count ||
      this == HabitTargetKind.duration ||
      this == HabitTargetKind.quantity;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static HabitTargetKind fromWire(String wire) {
    for (final HabitTargetKind kind in HabitTargetKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown habit target kind: $wire');
  }
}

/// The immutable target configuration of one habit schedule version.
///
/// The named constructors are the only way to build a target, so the per-kind
/// invariants of R-HABIT-002 are always upheld. Zero/negative targets, a unit
/// on a kind that forbids one, and a missing unit on a kind that requires one
/// are all rejected at construction (R-HABIT-003).
final class HabitTarget {
  const HabitTarget._({
    required this.kind,
    this.targetValue,
    this.unit,
    this.displayUnit,
  });

  /// A boolean target: completes on an explicit true check-in; no value/unit.
  factory HabitTarget.boolean() =>
      const HabitTarget._(kind: HabitTargetKind.boolean);

  /// An abstinence target: no value/unit; completes on close with no violation.
  factory HabitTarget.abstinence() =>
      const HabitTarget._(kind: HabitTargetKind.abstinence);

  /// A count target: a positive integer number of observations; no unit.
  factory HabitTarget.count(int targetValue) {
    _requirePositive(targetValue, HabitTargetKind.count);
    return HabitTarget._(kind: HabitTargetKind.count, targetValue: targetValue);
  }

  /// A duration target of [targetSeconds] canonical seconds, preserving the
  /// entered [displayUnit] (for example `minutes` or `hours`).
  factory HabitTarget.duration({
    required int targetSeconds,
    required String displayUnit,
  }) {
    _requirePositive(targetSeconds, HabitTargetKind.duration);
    if (displayUnit.trim().isEmpty) {
      throw const FormatException('A duration target requires a display unit.');
    }
    return HabitTarget._(
      kind: HabitTargetKind.duration,
      targetValue: targetSeconds,
      displayUnit: displayUnit,
    );
  }

  /// A quantity target of [targetValue] canonical units in the dimension of
  /// [unit]; a unit is required.
  factory HabitTarget.quantity({
    required int targetValue,
    required String unit,
  }) {
    _requirePositive(targetValue, HabitTargetKind.quantity);
    if (unit.trim().isEmpty) {
      throw const FormatException('A quantity target requires a unit.');
    }
    return HabitTarget._(
      kind: HabitTargetKind.quantity,
      targetValue: targetValue,
      unit: unit,
    );
  }

  final HabitTargetKind kind;

  /// The positive integer target for numeric kinds; null for boolean and
  /// abstinence. For duration it is canonical seconds; for quantity it is the
  /// canonical-unit total of [unit]'s dimension.
  final int? targetValue;

  /// The required unit for a quantity target; null for every other kind.
  final String? unit;

  /// The entered display unit preserved for a duration target; null otherwise.
  final String? displayUnit;

  static void _requirePositive(int value, HabitTargetKind kind) {
    if (value <= 0) {
      throw FormatException(
        'A ${kind.wire} target_value must be positive: $value',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HabitTarget &&
      other.kind == kind &&
      other.targetValue == targetValue &&
      other.unit == unit &&
      other.displayUnit == displayUnit;

  @override
  int get hashCode => Object.hash(kind, targetValue, unit, displayUnit);
}
