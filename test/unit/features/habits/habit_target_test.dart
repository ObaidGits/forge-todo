import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// Authoritative target-kind constraints (R-HABIT-002, R-HABIT-003).
void main() {
  group('boolean and abstinence targets', () {
    test('carry no target value or unit', () {
      final HabitTarget boolean = HabitTarget.boolean();
      expect(boolean.kind, HabitTargetKind.boolean);
      expect(boolean.targetValue, isNull);
      expect(boolean.unit, isNull);
      expect(boolean.displayUnit, isNull);

      final HabitTarget abstinence = HabitTarget.abstinence();
      expect(abstinence.kind, HabitTargetKind.abstinence);
      expect(abstinence.targetValue, isNull);
      expect(abstinence.unit, isNull);
    });
  });

  group('count targets', () {
    test('require a positive integer and carry no unit', () {
      final HabitTarget count = HabitTarget.count(3);
      expect(count.targetValue, 3);
      expect(count.unit, isNull);
    });

    test('reject a zero or negative target', () {
      expect(() => HabitTarget.count(0), throwsFormatException);
      expect(() => HabitTarget.count(-1), throwsFormatException);
    });
  });

  group('duration targets', () {
    test('store canonical seconds while preserving the display unit', () {
      final HabitTarget duration = HabitTarget.duration(
        targetSeconds: 1800,
        displayUnit: 'minutes',
      );
      expect(duration.targetValue, 1800);
      expect(duration.displayUnit, 'minutes');
      expect(duration.unit, isNull);
    });

    test('reject a non-positive target or an empty display unit', () {
      expect(
        () => HabitTarget.duration(targetSeconds: 0, displayUnit: 'minutes'),
        throwsFormatException,
      );
      expect(
        () => HabitTarget.duration(targetSeconds: 60, displayUnit: '  '),
        throwsFormatException,
      );
    });
  });

  group('quantity targets', () {
    test('require a positive target and a unit', () {
      final HabitTarget quantity = HabitTarget.quantity(
        targetValue: 2000,
        unit: 'ml',
      );
      expect(quantity.targetValue, 2000);
      expect(quantity.unit, 'ml');
      expect(quantity.displayUnit, isNull);
    });

    test('reject a missing unit or a non-positive target', () {
      expect(
        () => HabitTarget.quantity(targetValue: 100, unit: ''),
        throwsFormatException,
      );
      expect(
        () => HabitTarget.quantity(targetValue: 0, unit: 'ml'),
        throwsFormatException,
      );
    });
  });

  test('kind wire round-trips and rejects unknown values', () {
    for (final HabitTargetKind kind in HabitTargetKind.values) {
      expect(HabitTargetKind.fromWire(kind.wire), kind);
    }
    expect(
      () => HabitTargetKind.fromWire('weekly_count'),
      throwsFormatException,
    );
  });
}
