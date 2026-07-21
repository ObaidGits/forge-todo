import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_preset.dart';

/// Preset proofs (R-FOCUS-004): Deep Work is a preset over the ordinary session
/// shape, not a separate data model.
///
/// **Validates: Requirements R-FOCUS-004**
void main() {
  group('[TEST-FOCUS-PRESET][MVP][TASK-7.3][R-FOCUS-004] presets resolve to '
      'ordinary session configuration', () {
    test('Deep Work resolves to an interval mode with a planned duration', () {
      expect(FocusPreset.deepWork.mode, FocusMode.interval);
      expect(FocusPreset.deepWork.plannedDurationSec, 90 * 60);
    });

    test(
      'the freeform preset resolves to count-up with no planned duration',
      () {
        expect(FocusPreset.freeform.mode, FocusMode.countUp);
        expect(FocusPreset.freeform.plannedDurationSec, isNull);
      },
    );

    test('every interval preset carries a positive planned duration', () {
      for (final FocusPreset preset in FocusPreset.values) {
        if (preset.mode == FocusMode.interval) {
          expect(preset.plannedDurationSec, greaterThan(0));
        } else {
          expect(preset.plannedDurationSec, isNull);
        }
      }
    });

    test('wire round-trips for every preset', () {
      for (final FocusPreset preset in FocusPreset.values) {
        expect(FocusPreset.fromWire(preset.wire), preset);
      }
      expect(() => FocusPreset.fromWire('nope'), throwsFormatException);
    });
  });
}
