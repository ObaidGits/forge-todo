import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/domain/habit_unit_normalizer.dart';

/// Compatible-unit normalization for quantity/duration observations
/// (R-HABIT-002, R-HABIT-003).
void main() {
  group('quantity normalization', () {
    test('normalizes compatible units to the target canonical amount', () {
      expect(
        HabitUnitNormalizer.normalizeToTarget(
          targetUnit: 'ml',
          observationUnit: 'l',
          value: 1,
        ),
        1000,
      );
      expect(
        HabitUnitNormalizer.normalizeToTarget(
          targetUnit: 'kg',
          observationUnit: 'g',
          value: 500,
        ),
        500000,
      );
    });

    test('rejects incompatible dimensions', () {
      expect(
        () => HabitUnitNormalizer.normalizeToTarget(
          targetUnit: 'ml',
          observationUnit: 'kg',
          value: 1,
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

    test('rejects an unknown unit', () {
      expect(
        () => HabitUnitNormalizer.normalizeToTarget(
          targetUnit: 'ml',
          observationUnit: 'furlong',
          value: 1,
        ),
        throwsA(
          isA<UnitConversionError>().having(
            (UnitConversionError e) => e.code,
            'code',
            'unknown_unit',
          ),
        ),
      );
    });

    test('rejects a negative observation', () {
      expect(
        () => HabitUnitNormalizer.normalizeToTarget(
          targetUnit: 'ml',
          observationUnit: 'ml',
          value: -1,
        ),
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

  group('duration normalization', () {
    test('converts a display unit to canonical seconds', () {
      expect(
        HabitUnitNormalizer.durationToSeconds(
          displayUnit: 'minutes',
          value: 30,
        ),
        1800,
      );
      expect(
        HabitUnitNormalizer.durationToSeconds(displayUnit: 'hours', value: 2),
        7200,
      );
    });

    test('rejects a non-time display unit', () {
      expect(
        () =>
            HabitUnitNormalizer.durationToSeconds(displayUnit: 'ml', value: 1),
        throwsA(isA<UnitConversionError>()),
      );
    });
  });
}
