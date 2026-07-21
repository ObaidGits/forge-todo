import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/fitness/domain/fitness_unit_normalizer.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';

/// A [MeasuredQuantity] preserves the entered value/unit while deriving a
/// canonical amount for computation (R-FIT-002).
void main() {
  test('preserves the exact entered value and unit', () {
    final MeasuredQuantity weight = MeasuredQuantity.of(80.5, 'kg');
    expect(weight.enteredValue, 80.5);
    expect(weight.enteredUnit, 'kg');
    expect(weight.dimension, 'mass');
    expect(weight.canonicalValue, 80500000);
  });

  test('displayIn returns the exact entered value for the entered unit', () {
    final MeasuredQuantity weight = MeasuredQuantity.of(135, 'lb');
    // Requesting the entered unit is exact, not a lossy round trip.
    expect(weight.displayIn('lb'), 135);
  });

  test('displayIn converts to a compatible unit', () {
    final MeasuredQuantity weight = MeasuredQuantity.of(1, 'kg');
    expect(weight.displayIn('g'), closeTo(1000, 1e-9));
  });

  test('fromStored reconstructs the exact entered value without recompute', () {
    // Even if the canonical amount were stale, the entered value is authoritative.
    final MeasuredQuantity restored = MeasuredQuantity.fromStored(
      enteredValue: 80.5,
      enteredUnit: 'kg',
      canonicalValue: 80500000,
    );
    expect(restored.enteredValue, 80.5);
    expect(restored.enteredUnit, 'kg');
    expect(restored, MeasuredQuantity.of(80.5, 'kg'));
  });

  test('rejects an unknown unit', () {
    expect(
      () => MeasuredQuantity.of(1, 'furlong'),
      throwsA(isA<UnitConversionError>()),
    );
  });

  test('rejects a negative entered value', () {
    expect(
      () => MeasuredQuantity.of(-1, 'kg'),
      throwsA(
        isA<UnitConversionError>().having(
          (UnitConversionError e) => e.code,
          'code',
          'negative_value',
        ),
      ),
    );
  });
}
