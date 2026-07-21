import 'package:forge/features/fitness/domain/fitness_unit_normalizer.dart';

/// A fitness measurement that preserves the exact value and unit as entered
/// while carrying a canonical integer amount for computation (R-FIT-001,
/// R-FIT-002).
///
/// The [enteredValue]/[enteredUnit] pair is authoritative for display: it is
/// stored and read back verbatim, so a body-weight of `80.5 kg` or a lift of
/// `135 lb` never drifts through rounding. The [canonicalValue] is the derived
/// integer amount in the dimension's canonical base (milligrams for mass,
/// millimetres for length, seconds for time) used only for comparison,
/// aggregation, and cross-unit history rendering.
final class MeasuredQuantity {
  const MeasuredQuantity._({
    required this.enteredValue,
    required this.enteredUnit,
    required this.dimension,
    required this.canonicalValue,
  });

  /// Builds a measurement from an entered [value] and [unit], deriving the
  /// canonical amount. Throws [UnitConversionError] for an unknown unit or a
  /// negative value.
  factory MeasuredQuantity.of(num value, String unit) {
    final int canonical = FitnessUnitNormalizer.toCanonical(
      unit: unit,
      value: value,
    );
    return MeasuredQuantity._(
      enteredValue: value,
      enteredUnit: unit,
      dimension: FitnessUnitNormalizer.dimensionOf(unit)!,
      canonicalValue: canonical,
    );
  }

  /// Reconstructs a measurement from persisted columns without recomputing the
  /// canonical amount, so the exact entered value survives a round trip even if
  /// the conversion table were to change.
  factory MeasuredQuantity.fromStored({
    required num enteredValue,
    required String enteredUnit,
    required int canonicalValue,
  }) {
    final String? dimension = FitnessUnitNormalizer.dimensionOf(enteredUnit);
    if (dimension == null) {
      throw UnitConversionError('unknown_unit', detail: enteredUnit);
    }
    return MeasuredQuantity._(
      enteredValue: enteredValue,
      enteredUnit: enteredUnit,
      dimension: dimension,
      canonicalValue: canonicalValue,
    );
  }

  /// The exact numeric value the user entered.
  final num enteredValue;

  /// The exact unit the user entered (preserved for display).
  final String enteredUnit;

  /// The physical dimension: `mass`, `length`, or `time`.
  final String dimension;

  /// The derived canonical integer amount (mg / mm / seconds).
  final int canonicalValue;

  /// Renders this quantity in [unit], preserving magnitude across compatible
  /// units. Requesting the [enteredUnit] returns the exact entered value.
  double displayIn(String unit) {
    if (unit.toLowerCase() == enteredUnit.toLowerCase()) {
      return enteredValue.toDouble();
    }
    return FitnessUnitNormalizer.convert(
      value: enteredValue,
      fromUnit: enteredUnit,
      toUnit: unit,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MeasuredQuantity &&
      other.enteredValue == enteredValue &&
      other.enteredUnit == enteredUnit &&
      other.dimension == dimension &&
      other.canonicalValue == canonicalValue;

  @override
  int get hashCode =>
      Object.hash(enteredValue, enteredUnit, dimension, canonicalValue);

  @override
  String toString() => '$enteredValue $enteredUnit';
}
