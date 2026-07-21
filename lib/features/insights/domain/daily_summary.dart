import 'package:forge/features/insights/domain/metric_policy.dart';

/// The as-of-close tally of a day's habit occurrences captured in the immutable
/// factual close (R-HOME-004, R-HABIT-007).
///
/// Counts are taken from the sealed close items, so they reflect the factual
/// close and never later mutation. The [completion] ratio applies metric policy
/// v1: a [paused] occurrence is ineligible and excluded from the denominator,
/// while a [skipped] occurrence stays in the denominator but never the
/// numerator (R-HABIT-007). This is a single day's display tally, not the
/// streak; the streak/consistency range metric remains owned by the habits
/// feature under the same policy version.
final class DailyHabitOutcomes {
  DailyHabitOutcomes({
    this.completed = 0,
    this.missed = 0,
    this.skipped = 0,
    this.paused = 0,
    this.open = 0,
  }) {
    if (completed < 0 || missed < 0 || skipped < 0 || paused < 0 || open < 0) {
      throw const FormatException('Habit outcome counts must be nonnegative.');
    }
  }

  final int completed;
  final int missed;
  final int skipped;
  final int paused;
  final int open;

  /// Every scheduled occurrence captured at close, including paused ones.
  int get total => completed + missed + skipped + paused + open;

  /// Completed eligible occurrences over all eligible (non-paused) occurrences
  /// under metric policy v1 (R-HABIT-007). A zero denominator is "no data".
  MetricRatio get completion =>
      MetricRatio(numerator: completed, denominator: total - paused);
}

/// The composed Daily Summary for one planning day (R-HOME-004).
///
/// It is assembled entirely from the immutable factual close plus the canonical
/// interval-union time metric, and it is stamped with the displayed metric
/// policy version and the source watermark that makes it reproducible
/// (R-INSIGHT-004). It never carries an opaque score: every metric exposes its
/// numerator/denominator or its underlying seconds.
///
/// Because task completion and habit outcomes are read from the sealed close,
/// a later source correction or policy recomputation ([adjustmentCount] > 0)
/// leaves this as-of-close summary unchanged; corrections append linked
/// adjustment records rather than rewriting the close (R-PLAN-003, R-HABIT-005).
final class DailySummary {
  DailySummary({
    required this.lifeAreaId,
    required this.dayKey,
    required this.taskCompletion,
    required this.habits,
    required this.combinedFocusStudySeconds,
    required this.focusStudyOverlapSeconds,
    required this.metricPolicyNumber,
    required this.sourceWatermarkCommitSeq,
    required this.closedAtUtc,
    required this.boundaryUtc,
    required this.eligibleRootHash,
    required this.completedRootHash,
    this.adjustmentCount = 0,
    this.reflectionMd,
  }) {
    if (combinedFocusStudySeconds < 0 || focusStudyOverlapSeconds < 0) {
      throw const FormatException('Combined-time seconds must be nonnegative.');
    }
    if (adjustmentCount < 0) {
      throw const FormatException('Adjustment count must be nonnegative.');
    }
  }

  /// The Life Area this summary is scoped to.
  final String lifeAreaId;

  /// The ISO `YYYY-MM-DD` planning-day key.
  final String dayKey;

  /// Completed eligible tasks over the set-union eligible set, as-of-close.
  final MetricRatio taskCompletion;

  /// The as-of-close habit occurrence tally.
  final DailyHabitOutcomes habits;

  /// Focus + study time in whole seconds, unioned so overlapping focus/study
  /// time is counted once (R-FOCUS-005, R-INSIGHT-001).
  final int combinedFocusStudySeconds;

  /// The focus/study time removed by the interval-union, in whole seconds.
  final int focusStudyOverlapSeconds;

  /// The numeric metric policy in effect at close.
  final int metricPolicyNumber;

  /// The commit sequence the factual close observed. The summary is reproducible
  /// from this watermark under [metricPolicyVersion] (R-INSIGHT-004).
  final int sourceWatermarkCommitSeq;

  /// The instant the factual close was taken.
  final int closedAtUtc;

  /// The planning-day boundary at which "missed" was evaluated.
  final int boundaryUtc;

  /// Deterministic root hash over the eligible task set at close, for audit and
  /// reproduction.
  final String eligibleRootHash;

  /// Deterministic root hash over the completed task set at close.
  final String completedRootHash;

  /// The number of linked adjustments appended after close; informational only,
  /// since they never change these as-of-close values (R-PLAN-003).
  final int adjustmentCount;

  /// The day's private evening reflection Markdown, or null when none was
  /// written (R-PLAN-004).
  final String? reflectionMd;

  /// The displayed metric policy version label (e.g. `metric-policy-v1`).
  String get metricPolicyVersion => MetricPolicyV1.label(metricPolicyNumber);
}
