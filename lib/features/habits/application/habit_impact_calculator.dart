import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';

/// Pure projection of the metric impact of a backfilled or corrected check-in
/// (R-HABIT-005, R-HABIT-007).
///
/// The calculator never touches persistence or a clock. It takes the current
/// key-ordered period outcomes and a single hypothetical change at a known
/// position, then computes the streak and consistency both before and after
/// through the sole authoritative [HabitMetricPolicyV1]. Because it defers every
/// metric decision to that policy, a preview can never diverge from the value
/// the user will see once the change is committed.
abstract final class HabitImpactCalculator {
  /// The impact of replacing the outcome at [index] with [replacement], or —
  /// when [index] equals `before.length` — inserting a backfilled occurrence at
  /// the end of the ordered window.
  ///
  /// [before] MUST be ordered by occurrence key (the same order the metric
  /// policy walks). [index] must be in `0..before.length`.
  static HabitImpactPreview replacing({
    required List<HabitPeriodOutcome> before,
    required int index,
    required HabitPreviewOutcome replacement,
  }) {
    if (index < 0 || index > before.length) {
      throw RangeError.range(index, 0, before.length, 'index');
    }
    final List<HabitPeriodOutcome> after = List<HabitPeriodOutcome>.of(before);
    if (index == after.length) {
      after.add(replacement.asPeriodOutcome);
    } else {
      after[index] = replacement.asPeriodOutcome;
    }
    return preview(before: before, after: after);
  }

  /// The impact given fully-formed [before] and [after] ordered outcome lists.
  static HabitImpactPreview preview({
    required List<HabitPeriodOutcome> before,
    required List<HabitPeriodOutcome> after,
  }) {
    return HabitImpactPreview(
      streakBefore: HabitMetricPolicyV1.currentStreak(before),
      streakAfter: HabitMetricPolicyV1.currentStreak(after),
      consistencyBefore: HabitMetricPolicyV1.consistency(before),
      consistencyAfter: HabitMetricPolicyV1.consistency(after),
    );
  }
}
