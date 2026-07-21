import 'package:forge/features/goals/domain/goal_progress_mode.dart';

/// One weighted progress leaf for a derived goal (R-GOAL-004).
///
/// In V1 the only progress leaves are roadmap topics (supplied by task 6.2);
/// this goal-side type is the seam the derived policy consumes so the goal
/// feature never needs to know the roadmap schema. A leaf is [eligible] unless
/// its topic is archived or cancelled. A completed leaf contributes its
/// nonnegative [weight]; a null weight normalizes to `1`.
final class GoalProgressLeaf {
  GoalProgressLeaf({
    required this.eligible,
    required this.completed,
    this.weight,
  }) {
    if (weight != null && weight! < 0) {
      throw const FormatException('Topic weight must be nonnegative.');
    }
  }

  final bool eligible;
  final bool completed;

  /// The topic's nonnegative completion weight, or null to normalize to `1`.
  final num? weight;

  /// The effective weight after null-normalization (R-GOAL-004).
  num get normalizedWeight => weight ?? 1;
}

/// The transparent progress surface for a goal (R-GOAL-004).
///
/// Progress is never persisted as authoritative; it is recomputed from source.
/// The surface always exposes the [formula], the [eligibleCount] of contributing
/// leaves, and the [totalWeight] so the UI can show exactly how a value was
/// derived. [value] is null when there is no computable progress (manual value
/// absent, or zero eligible total weight in derived mode) — rendered as
/// "not started / no computable progress" rather than 0%.
final class GoalProgress {
  const GoalProgress({
    required this.mode,
    required this.value,
    required this.formula,
    required this.eligibleCount,
    required this.totalWeight,
    required this.completedWeight,
  });

  final GoalProgressMode mode;

  /// The fraction in `0..1`, or null when no progress is computable.
  final double? value;

  /// A human-readable, reproducible description of how [value] was derived.
  final String formula;

  /// The number of eligible contributing leaves (0 in manual mode).
  final int eligibleCount;

  /// The sum of eligible leaf weights (0 in manual mode).
  final num totalWeight;

  /// The sum of completed eligible leaf weights (0 in manual mode).
  final num completedWeight;

  /// True when a concrete progress fraction is available.
  bool get isComputable => value != null;
}

/// Pure goal progress policies (R-GOAL-004). No persistence, no double count.
abstract final class GoalProgressPolicy {
  /// The transparent formula string shared by every derived computation.
  static const String derivedFormula =
      'completed_eligible_topic_weight / eligible_topic_weight';

  /// The formula string for a manually-entered goal value.
  static const String manualFormula = 'manual(clamped 0..1)';

  /// Clamps a raw manual value into the inclusive `0..1` range (R-GOAL-004).
  static double clampManual(double raw) {
    if (raw.isNaN) {
      return 0;
    }
    return raw.clamp(0.0, 1.0).toDouble();
  }

  /// Builds the manual progress surface from a stored [rawValue]. A null value
  /// yields "no computable progress".
  static GoalProgress manual(double? rawValue) {
    return GoalProgress(
      mode: GoalProgressMode.manual,
      value: rawValue == null ? null : clampManual(rawValue),
      formula: manualFormula,
      eligibleCount: 0,
      totalWeight: 0,
      completedWeight: 0,
    );
  }

  /// Computes derived progress from roadmap topic [leaves] (R-GOAL-004).
  ///
  /// Only eligible leaves contribute. Each eligible leaf's weight is its
  /// null-normalized nonnegative weight; a completed eligible leaf also adds
  /// that weight to the numerator. A zero eligible total weight yields "not
  /// started / no computable progress" (null [GoalProgress.value]).
  static GoalProgress derived(Iterable<GoalProgressLeaf> leaves) {
    num total = 0;
    num completed = 0;
    int eligible = 0;
    for (final GoalProgressLeaf leaf in leaves) {
      if (!leaf.eligible) {
        continue;
      }
      eligible += 1;
      total += leaf.normalizedWeight;
      if (leaf.completed) {
        completed += leaf.normalizedWeight;
      }
    }
    final double? value = total == 0 ? null : (completed / total).toDouble();
    return GoalProgress(
      mode: GoalProgressMode.derived,
      value: value,
      formula: derivedFormula,
      eligibleCount: eligible,
      totalWeight: total,
      completedWeight: completed,
    );
  }
}
