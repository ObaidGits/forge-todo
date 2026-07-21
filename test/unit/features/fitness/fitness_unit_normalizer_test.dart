import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/fitness/domain/fitness_unit_normalizer.dart';

/// Canonical unit normalization and conversion for fitness measurements
/// (R-FIT-001, R-FIT-002).
void main() {
  group('toCanonical', () {
    test('normalizes mass units to canonical milligrams', () {
      expect(FitnessUnitNormalizer.toCanonical(unit: 'kg', value: 1), 1000000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'g', value: 1), 1000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'lb', value: 1), 453592);
    });

    test('normalizes length units to canonical millimetres', () {
      expect(FitnessUnitNormalizer.toCanonical(unit: 'km', value: 1), 1000000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'm', value: 1), 1000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'mi', value: 1), 1609344);
    });

    test('normalizes volume units to canonical microlitres (R-FIT-003)', () {
      expect(FitnessUnitNormalizer.toCanonical(unit: 'ml', value: 1), 1000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'l', value: 1), 1000000);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'floz', value: 1), 29574);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'ml', value: 500), 500000);
    });

    test('normalizes time units to canonical seconds', () {
      expect(FitnessUnitNormalizer.toCanonical(unit: 'min', value: 1), 60);
      expect(FitnessUnitNormalizer.toCanonical(unit: 'hour', value: 1), 3600);
    });

    test('rejects an unknown unit', () {
      expect(
        () => FitnessUnitNormalizer.toCanonical(unit: 'furlong', value: 1),
        throwsA(
          isA<UnitConversionError>().having(
            (UnitConversionError e) => e.code,
            'code',
            'unknown_unit',
          ),
        ),
      );
    });

    test('rejects a negative value', () {
      expect(
        () => FitnessUnitNormalizer.toCanonical(unit: 'kg', value: -1),
        throwsA(
          isA<UnitConversionError>().having(
            (UnitConversionError e) => e.code,
            'code',
            'negative_value',
          ),
        ),
      );
    });
  });

  group('convert', () {
    test('converts across compatible mass units preserving magnitude', () {
      expect(
        FitnessUnitNormalizer.convert(value: 1, fromUnit: 'kg', toUnit: 'g'),
        closeTo(1000, 1e-9),
      );
      // 100 kg is about 220.46 lb.
      expect(
        FitnessUnitNormalizer.convert(value: 100, fromUnit: 'kg', toUnit: 'lb'),
        closeTo(220.462, 0.01),
      );
    });

    test('converts across compatible volume units (R-FIT-003)', () {
      expect(
        FitnessUnitNormalizer.convert(value: 1, fromUnit: 'l', toUnit: 'ml'),
        closeTo(1000, 1e-9),
      );
      // 1 US fluid ounce is about 29.57 ml.
      expect(
        FitnessUnitNormalizer.convert(value: 1, fromUnit: 'floz', toUnit: 'ml'),
        closeTo(29.574, 0.01),
      );
    });

    test('converts across compatible length units', () {
      expect(
        FitnessUnitNormalizer.convert(value: 5, fromUnit: 'km', toUnit: 'm'),
        closeTo(5000, 1e-9),
      );
    });

    test('rejects incompatible dimensions', () {
      expect(
        () => FitnessUnitNormalizer.convert(
          value: 1,
          fromUnit: 'kg',
          toUnit: 'm',
        ),
        throwsA(
          isA<UnitConversionError>().having(
            (UnitConversionError e) => e.code,
            'code',
            'incompatible_units',
          ),
        ),
      );
    });
  });

  group('dimensionOf / areCompatible', () {
    test('classifies units by dimension', () {
      expect(FitnessUnitNormalizer.dimensionOf('kg'), 'mass');
      expect(FitnessUnitNormalizer.dimensionOf('km'), 'length');
      expect(FitnessUnitNormalizer.dimensionOf('min'), 'time');
      expect(FitnessUnitNormalizer.dimensionOf('ml'), 'volume');
      expect(FitnessUnitNormalizer.dimensionOf('floz'), 'volume');
      // Mass `oz` never aliases fluid ounces (R-FIT-003).
      expect(FitnessUnitNormalizer.dimensionOf('oz'), 'mass');
      expect(FitnessUnitNormalizer.dimensionOf('nope'), isNull);
    });

    test('reports compatibility within a dimension', () {
      expect(FitnessUnitNormalizer.areCompatible('kg', 'lb'), isTrue);
      expect(FitnessUnitNormalizer.areCompatible('kg', 'km'), isFalse);
    });
  });
}
