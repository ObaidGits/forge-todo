/// Canonical unit normalization and conversion for fitness measurements
/// (R-FIT-001, R-FIT-002).
///
/// Fitness records preserve the exact value and unit a person entered (a
/// body-weight of `80 kg` or a bench press of `135 lb` is stored verbatim),
/// while a canonical integer amount is derived for computation, comparison, and
/// history aggregation. This mirrors the habits duration/quantity
/// unit-preservation pattern (`lib/features/habits`): a canonical stored value
/// plus a preserved display unit.
///
/// The registry is intentionally small and pure — it names no locale or plugin
/// dependency — so accumulation and conversion are deterministic and testable.
/// Three dimensions are supported:
///
/// * `mass`   canonical: milligrams. Used for weights (kg/lb/g/oz/stone).
/// * `length` canonical: millimetres. Used for distances (km/mi/m/cm/ft/yd).
/// * `time`   canonical: seconds. Used for set/interval durations.
/// * `volume` canonical: microlitres. Used for optional water events
///   (ml/l/fl oz/cup/pint/quart/gallon) — a neutral quantity that preserves the
///   entered value/unit exactly (R-FIT-003). Fluid `oz` is entered as `floz` so
///   it never collides with mass `oz`.
///
/// An unknown unit, an incompatible-dimension conversion, or a negative value
/// is rejected with a stable [UnitConversionError] code so corrupt intent
/// surfaces rather than being silently coerced.
library;

/// A stable, presentation-safe unit error raised by [FitnessUnitNormalizer].
final class UnitConversionError implements Exception {
  const UnitConversionError(this.code, {this.detail});

  /// Stable code: `unknown_unit`, `incompatible_units`, or `negative_value`.
  final String code;
  final String? detail;

  @override
  String toString() =>
      'UnitConversionError($code${detail == null ? '' : ': $detail'})';
}

/// Pure canonical-unit registry and conversion helpers for fitness values.
abstract final class FitnessUnitNormalizer {
  /// Canonical scale factors keyed by lowercase unit, grouped by dimension.
  /// A value expressed in a unit multiplied by its factor yields the canonical
  /// amount for that dimension (milligrams / millimetres / seconds).
  static const Map<String, _Dimension> _units = <String, _Dimension>{
    // Mass (canonical: milligrams).
    'mg': _Dimension('mass', 1),
    'milligram': _Dimension('mass', 1),
    'g': _Dimension('mass', 1000),
    'gram': _Dimension('mass', 1000),
    'grams': _Dimension('mass', 1000),
    'kg': _Dimension('mass', 1000000),
    'kilogram': _Dimension('mass', 1000000),
    'kilograms': _Dimension('mass', 1000000),
    'lb': _Dimension('mass', 453592),
    'lbs': _Dimension('mass', 453592),
    'pound': _Dimension('mass', 453592),
    'pounds': _Dimension('mass', 453592),
    'oz': _Dimension('mass', 28350),
    'ounce': _Dimension('mass', 28350),
    'ounces': _Dimension('mass', 28350),
    'st': _Dimension('mass', 6350293),
    'stone': _Dimension('mass', 6350293),
    // Length / distance (canonical: millimetres).
    'mm': _Dimension('length', 1),
    'millimetre': _Dimension('length', 1),
    'millimeter': _Dimension('length', 1),
    'cm': _Dimension('length', 10),
    'centimetre': _Dimension('length', 10),
    'centimeter': _Dimension('length', 10),
    'm': _Dimension('length', 1000),
    'metre': _Dimension('length', 1000),
    'meter': _Dimension('length', 1000),
    'metres': _Dimension('length', 1000),
    'meters': _Dimension('length', 1000),
    'km': _Dimension('length', 1000000),
    'kilometre': _Dimension('length', 1000000),
    'kilometer': _Dimension('length', 1000000),
    'mi': _Dimension('length', 1609344),
    'mile': _Dimension('length', 1609344),
    'miles': _Dimension('length', 1609344),
    'ft': _Dimension('length', 305),
    'foot': _Dimension('length', 305),
    'feet': _Dimension('length', 305),
    'yd': _Dimension('length', 914),
    'yard': _Dimension('length', 914),
    'yards': _Dimension('length', 914),
    // Time (canonical: seconds).
    'second': _Dimension('time', 1),
    'seconds': _Dimension('time', 1),
    'sec': _Dimension('time', 1),
    's': _Dimension('time', 1),
    'minute': _Dimension('time', 60),
    'minutes': _Dimension('time', 60),
    'min': _Dimension('time', 60),
    'hour': _Dimension('time', 3600),
    'hours': _Dimension('time', 3600),
    'hr': _Dimension('time', 3600),
    // Volume (canonical: microlitres). Used by optional water events
    // (R-FIT-003). Fluid ounces use 'floz' so they never alias mass 'oz'.
    'ml': _Dimension('volume', 1000),
    'millilitre': _Dimension('volume', 1000),
    'milliliter': _Dimension('volume', 1000),
    'millilitres': _Dimension('volume', 1000),
    'milliliters': _Dimension('volume', 1000),
    'cl': _Dimension('volume', 10000),
    'centilitre': _Dimension('volume', 10000),
    'centiliter': _Dimension('volume', 10000),
    'dl': _Dimension('volume', 100000),
    'decilitre': _Dimension('volume', 100000),
    'deciliter': _Dimension('volume', 100000),
    'l': _Dimension('volume', 1000000),
    'litre': _Dimension('volume', 1000000),
    'liter': _Dimension('volume', 1000000),
    'litres': _Dimension('volume', 1000000),
    'liters': _Dimension('volume', 1000000),
    'floz': _Dimension('volume', 29574),
    'fl_oz': _Dimension('volume', 29574),
    'fluidounce': _Dimension('volume', 29574),
    'fluid_ounce': _Dimension('volume', 29574),
    'cup': _Dimension('volume', 236588),
    'cups': _Dimension('volume', 236588),
    'pt': _Dimension('volume', 473176),
    'pint': _Dimension('volume', 473176),
    'pints': _Dimension('volume', 473176),
    'qt': _Dimension('volume', 946353),
    'quart': _Dimension('volume', 946353),
    'quarts': _Dimension('volume', 946353),
    'gal': _Dimension('volume', 3785412),
    'gallon': _Dimension('volume', 3785412),
    'gallons': _Dimension('volume', 3785412),
  };

  /// The dimension name of [unit], or null when the unit is unknown.
  static String? dimensionOf(String unit) => _units[unit.toLowerCase()]?.name;

  /// Whether [a] and [b] measure the same physical dimension.
  static bool areCompatible(String a, String b) {
    final String? da = dimensionOf(a);
    final String? db = dimensionOf(b);
    return da != null && da == db;
  }

  /// Normalizes [value] expressed in [unit] to the canonical integer amount of
  /// its dimension (milligrams / millimetres / seconds).
  ///
  /// Throws [UnitConversionError] with a stable code when the unit is unknown
  /// or the value is negative.
  static int toCanonical({required String unit, required num value}) {
    if (value < 0) {
      throw UnitConversionError('negative_value', detail: '$value');
    }
    final _Dimension? dimension = _units[unit.toLowerCase()];
    if (dimension == null) {
      throw UnitConversionError('unknown_unit', detail: unit);
    }
    return (value * dimension.factor).round();
  }

  /// Converts [value] expressed in [fromUnit] to [toUnit], preserving the
  /// numeric magnitude across compatible units.
  ///
  /// Throws [UnitConversionError] when either unit is unknown, the dimensions
  /// are incompatible, or the value is negative.
  static double convert({
    required num value,
    required String fromUnit,
    required String toUnit,
  }) {
    if (value < 0) {
      throw UnitConversionError('negative_value', detail: '$value');
    }
    final _Dimension? from = _units[fromUnit.toLowerCase()];
    final _Dimension? to = _units[toUnit.toLowerCase()];
    if (from == null) {
      throw UnitConversionError('unknown_unit', detail: fromUnit);
    }
    if (to == null) {
      throw UnitConversionError('unknown_unit', detail: toUnit);
    }
    if (from.name != to.name) {
      throw UnitConversionError(
        'incompatible_units',
        detail: '$fromUnit != $toUnit',
      );
    }
    return value * from.factor / to.factor;
  }

  /// Converts a canonical integer [canonical] amount of [dimension] back into
  /// [unit]. Used to render history in a requested unit without losing the
  /// preserved entered value stored alongside it.
  static double fromCanonical({required int canonical, required String unit}) {
    final _Dimension? target = _units[unit.toLowerCase()];
    if (target == null) {
      throw UnitConversionError('unknown_unit', detail: unit);
    }
    return canonical / target.factor;
  }
}

final class _Dimension {
  const _Dimension(this.name, this.factor);

  final String name;
  final int factor;
}
