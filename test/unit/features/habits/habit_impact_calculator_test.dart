import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/application/habit_impact_calculator.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';

/// Unit tests for the pure backfill/correction impact calculator (R-HABIT-005,
/// R-HABIT-007). The calculator must never diverge from [HabitMetricPolicyV1].
void main() {
  group('HabitImpactCalculator.replacing', () {
    test('marking the latest occurrence done extends the streak', () {
      final List<HabitPeriodOutcome> before = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.missed,
      ];
      final HabitImpactPreview preview = HabitImpactCalculator.replacing(
        before: before,
        index: 2,
        replacement: HabitPreviewOutcome.completed,
      );
      expect(preview.streakBefore, 0);
      expect(preview.streakAfter, 3);
      expect(preview.streakDelta, 3);
    });

    test('correcting a completed occurrence to missed breaks the streak', () {
      final List<HabitPeriodOutcome> before = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
      ];
      final HabitImpactPreview preview = HabitImpactCalculator.replacing(
        before: before,
        index: 2,
        replacement: HabitPreviewOutcome.missed,
      );
      expect(preview.streakBefore, 3);
      expect(preview.streakAfter, 0);
    });

    test('a skip keeps the denominator but never the numerator', () {
      final List<HabitPeriodOutcome> before = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.missed,
      ];
      final HabitImpactPreview preview = HabitImpactCalculator.replacing(
        before: before,
        index: 1,
        replacement: HabitPreviewOutcome.skipped,
      );
      // Consistency denominator unchanged (skip stays in denominator), and the
      // completed count is unchanged.
      expect(preview.consistencyBefore.denominator, 2);
      expect(preview.consistencyAfter.denominator, 2);
      expect(preview.consistencyBefore.completed, 1);
      expect(preview.consistencyAfter.completed, 1);
    });

    test('appending a backfilled occurrence at the end grows the window', () {
      final List<HabitPeriodOutcome> before = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
      ];
      final HabitImpactPreview preview = HabitImpactCalculator.replacing(
        before: before,
        index: before.length,
        replacement: HabitPreviewOutcome.completed,
      );
      expect(preview.consistencyAfter.denominator, 2);
      expect(preview.consistencyAfter.completed, 2);
      expect(preview.streakAfter, 2);
    });

    test('rejects an out-of-range index', () {
      expect(
        () => HabitImpactCalculator.replacing(
          before: const <HabitPeriodOutcome>[],
          index: 5,
          replacement: HabitPreviewOutcome.completed,
        ),
        throwsRangeError,
      );
    });

    test('carries the displayed metric-policy version', () {
      final HabitImpactPreview preview = HabitImpactCalculator.replacing(
        before: const <HabitPeriodOutcome>[HabitPeriodOutcome.completed],
        index: 0,
        replacement: HabitPreviewOutcome.missed,
      );
      expect(preview.metricPolicyVersion, kHabitMetricPolicyVersion);
    });
  });
}
