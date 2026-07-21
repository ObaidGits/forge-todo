/// Compatible-unit normalization for numeric habit observations (R-HABIT-002,
/// R-HABIT-003).
///
/// A `quantity` target sums values only after normalizing every observation to
/// the canonical unit of the target unit's dimension; an observation in an
/// incompatible dimension is rejected. A `duration` target normalizes an
/// entered display unit (seconds/minutes/hours) to canonical integer seconds
/// while the display unit is preserved on the target. Negative observations are
/// always rejected.
///
/// The registry is intentionally small and pure — it names no locale or plugin
/// dependency — but it demonstrates dimensional compatibility and rejection so
/// the accumulation semantics are deterministic.
final class UnitConversionError implements Exception {
  const UnitConversionError(this.code, {this.detail});

  /// Stable code: `unknown_unit`, `incompatible_units`, or `negative_value`.
  final String code;
  final String? detail;

  @override
  String toString() =>
      'UnitConversionError($code${detail == null ? '' : ': $detail'})';
}

abstract final class HabitUnitNormalizer {
  /// Canonical scale factors keyed by lowercase unit, grouped by dimension.
  /// A value expressed in a unit multiplied by its factor yields the canonical
  /// integer amount for that dimension.
  static const Map<String, _Dimension> _units = <String, _Dimension>{
    // Time (canonical: seconds).
    'second': _Dimension('time', 1),
    'seconds': _Dimension('time', 1),
    'sec': _Dimension('time', 1),
    'minute': _Dimension('time', 60),
    'minutes': _Dimension('time', 60),
    'min': _Dimension('time', 60),
    'hour': _Dimension('time', 3600),
    'hours': _Dimension('time', 3600),
    // Mass (canonical: grams).
    'mg': _Dimension('mass', 1),
    'milligram': _Dimension('mass', 1),
    'g': _Dimension('mass', 1000),
    'gram': _Dimension('mass', 1000),
    'grams': _Dimension('mass', 1000),
    'kg': _Dimension('mass', 1000000),
    'kilogram': _Dimension('mass', 1000000),
    // Volume (canonical: millilitres).
    'ml': _Dimension('volume', 1),
    'millilitre': _Dimension('volume', 1),
    'milliliter': _Dimension('volume', 1),
    'l': _Dimension('volume', 1000),
    'litre': _Dimension('volume', 1000),
    'liter': _Dimension('volume', 1000),
    // Length (canonical: metres).
    'm': _Dimension('length', 1),
    'metre': _Dimension('length', 1),
    'meter': _Dimension('length', 1),
    'km': _Dimension('length', 1000),
    'kilometre': _Dimension('length', 1000),
    'kilometer': _Dimension('length', 1000),
    // Count-like (canonical: units); a generic dimension for arbitrary units.
    'unit': _Dimension('count', 1),
    'units': _Dimension('count', 1),
    'rep': _Dimension('count', 1),
    'reps': _Dimension('count', 1),
    'page': _Dimension('count', 1),
    'pages': _Dimension('count', 1),
    'glass': _Dimension('count', 1),
    'glasses': _Dimension('count', 1),
  };

  /// The dimension name of [unit], or null when the unit is unknown.
  static String? dimensionOf(String unit) => _units[unit.toLowerCase()]?.name;

  /// Whether [observationUnit] can be summed against a target in [targetUnit].
  static bool areCompatible(String targetUnit, String observationUnit) {
    final String? a = dimensionOf(targetUnit);
    final String? b = dimensionOf(observationUnit);
    return a != null && a == b;
  }

  /// Normalizes [value] in [observationUnit] to the canonical integer amount of
  /// [targetUnit]'s dimension.
  ///
  /// Throws [UnitConversionError] with a stable code when the unit is unknown,
  /// the dimensions are incompatible, or the value is negative.
  static int normalizeToTarget({
    required String targetUnit,
    required String observationUnit,
    required num value,
  }) {
    if (value < 0) {
      throw UnitConversionError('negative_value', detail: '$value');
    }
    final _Dimension? target = _units[targetUnit.toLowerCase()];
    final _Dimension? observation = _units[observationUnit.toLowerCase()];
    if (target == null) {
      throw UnitConversionError('unknown_unit', detail: targetUnit);
    }
    if (observation == null) {
      throw UnitConversionError('unknown_unit', detail: observationUnit);
    }
    if (target.name != observation.name) {
      throw UnitConversionError(
        'incompatible_units',
        detail: '$observationUnit != $targetUnit',
      );
    }
    return (value * observation.factor).round();
  }

  /// Normalizes a duration [value] in [displayUnit] to canonical seconds.
  static int durationToSeconds({
    required String displayUnit,
    required num value,
  }) {
    if (value < 0) {
      throw UnitConversionError('negative_value', detail: '$value');
    }
    final _Dimension? unit = _units[displayUnit.toLowerCase()];
    if (unit == null || unit.name != 'time') {
      throw UnitConversionError('unknown_unit', detail: displayUnit);
    }
    return (value * unit.factor).round();
  }
}

final class _Dimension {
  const _Dimension(this.name, this.factor);

  final String name;
  final int factor;
}
