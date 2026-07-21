/// Metric policy v1 for habit streak and consistency (R-HABIT-004, R-HABIT-007).
///
/// This is the sole authoritative interpretation of streak continuity and
/// consistency for the MVP. Any future treatment change requires a new
/// displayed policy version and must never rewrite prior factual closes
/// (R-HABIT-007); this policy is therefore a pure function of period outcomes.
library;

/// The metric-relevant outcome of one eligible-or-ignored scheduled occurrence
/// or aggregate period, ordered by occurrence key.
enum HabitPeriodOutcome {
  /// The target was met for this dated occurrence / aggregate period.
  completed,

  /// The period closed without the target being met, or an abstinence
  /// violation was recorded.
  missed,

  /// The user explicitly skipped this occurrence with a reason.
  skipped,

  /// The occurrence was paused; it is ineligible and ignored by both metrics.
  paused,

  /// The occurrence is not yet closed and not yet complete.
  open,
}

/// The stable version tag displayed alongside every metric computed here.
const String kHabitMetricPolicyVersion = 'metric-policy-v1';

/// A consistency computation with its transparent numerator/denominator
/// (R-HABIT-007). [ratio] is null exactly when [denominator] is zero, which the
/// UI renders as "no eligible data" rather than 0%.
final class HabitConsistency {
  const HabitConsistency({required this.completed, required this.denominator});

  final int completed;
  final int denominator;

  /// The consistency ratio in 0..1, or null when there is no eligible data.
  double? get ratio => denominator == 0 ? null : completed / denominator;

  bool get hasData => denominator > 0;
}

abstract final class HabitMetricPolicyV1 {
  /// The streak length ending at [index] within the key-ordered [outcomes],
  /// walking backward under metric policy v1.
  ///
  /// The occurrence at [index] must be [HabitPeriodOutcome.completed] to start a
  /// streak; otherwise the streak is 0. Walking backward: paused and skipped
  /// occurrences are stepped over without counting and without breaking
  /// continuity; a completed occurrence increments the streak; a missed,
  /// violation (surfaced as missed), incomplete-closed, or open occurrence
  /// stops the walk. Non-scheduled dates are simply absent from [outcomes] and
  /// therefore never break the streak.
  static int streakEndingAt(List<HabitPeriodOutcome> outcomes, int index) {
    if (index < 0 || index >= outcomes.length) {
      return 0;
    }
    if (outcomes[index] != HabitPeriodOutcome.completed) {
      return 0;
    }
    int streak = 0;
    for (int i = index; i >= 0; i--) {
      switch (outcomes[i]) {
        case HabitPeriodOutcome.completed:
          streak += 1;
        case HabitPeriodOutcome.paused:
        case HabitPeriodOutcome.skipped:
          // Neutral: step over without counting or breaking continuity.
          break;
        case HabitPeriodOutcome.missed:
        case HabitPeriodOutcome.open:
          return streak;
      }
    }
    return streak;
  }

  /// The current streak: the streak ending at the last non-paused, non-skipped
  /// occurrence, or 0 when the most recent decisive occurrence is not complete.
  static int currentStreak(List<HabitPeriodOutcome> outcomes) {
    for (int i = outcomes.length - 1; i >= 0; i--) {
      final HabitPeriodOutcome outcome = outcomes[i];
      if (outcome == HabitPeriodOutcome.paused ||
          outcome == HabitPeriodOutcome.skipped) {
        continue;
      }
      return streakEndingAt(outcomes, i);
    }
    return 0;
  }

  /// Consistency over [outcomes] under metric policy v1: completed eligible
  /// occurrences over all eligible scheduled occurrences. Paused occurrences are
  /// excluded from both; skips remain in the denominator but never the
  /// numerator (R-HABIT-007).
  static HabitConsistency consistency(List<HabitPeriodOutcome> outcomes) {
    int completed = 0;
    int denominator = 0;
    for (final HabitPeriodOutcome outcome in outcomes) {
      if (outcome == HabitPeriodOutcome.paused) {
        continue;
      }
      denominator += 1;
      if (outcome == HabitPeriodOutcome.completed) {
        completed += 1;
      }
    }
    return HabitConsistency(completed: completed, denominator: denominator);
  }
}
