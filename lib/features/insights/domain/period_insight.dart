import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';

/// A V1 weekly or monthly Insight aggregated from immutable factual daily
/// closes and interval-unioned focus/study time (R-INSIGHT-001, R-INSIGHT-002,
/// R-INSIGHT-004).
///
/// Every displayed figure is explainable, never an opaque score
/// (R-INSIGHT-005): task completion and habit consistency expose their
/// numerator/denominator through [MetricRatio], and combined focus/study time
/// exposes its underlying whole seconds and the overlap the interval-union
/// removed. The Insight is stamped with the displayed metric policy version and
/// the [sourceWatermarkCommitSeq] it was reproduced from, so recompute at the
/// same watermark yields the identical value (R-INSIGHT-004).
///
/// Zero-data is represented honestly: a metric whose denominator is zero has
/// `hasData == false` and must render as "no data", never a misleading 0%
/// (R-INSIGHT-002). An Insight with no closed days ([closedDayCount] == 0) has
/// no data at all and carries no reproducible watermark.
final class PeriodInsight {
  PeriodInsight({
    required this.period,
    required this.lifeAreaId,
    required this.taskCompletion,
    required this.missedCount,
    required this.carriedCount,
    required this.habitConsistency,
    required this.combinedFocusStudySeconds,
    required this.focusStudyOverlapSeconds,
    required this.metricPolicyNumber,
    required this.sourceWatermarkCommitSeq,
    required this.closedDayCount,
    required this.memberDayCount,
  }) {
    if (missedCount < 0 || carriedCount < 0) {
      throw const FormatException('Missed/carried counts must be nonnegative.');
    }
    if (carriedCount > missedCount) {
      throw FormatException(
        'Carried ($carriedCount) exceeds missed ($missedCount).',
      );
    }
    if (combinedFocusStudySeconds < 0 || focusStudyOverlapSeconds < 0) {
      throw const FormatException('Combined-time seconds must be nonnegative.');
    }
    if (closedDayCount < 0 || memberDayCount < 0) {
      throw const FormatException('Day counts must be nonnegative.');
    }
    if (closedDayCount > memberDayCount) {
      throw FormatException(
        'Closed days ($closedDayCount) exceed member days ($memberDayCount).',
      );
    }
  }

  /// An Insight for a window that has no closed days yet: every metric is
  /// no-data and there is no reproducible watermark.
  factory PeriodInsight.empty(InsightPeriod period, {String? lifeAreaId}) =>
      PeriodInsight(
        period: period,
        lifeAreaId: lifeAreaId,
        taskCompletion: const MetricRatio.empty(),
        missedCount: 0,
        carriedCount: 0,
        habitConsistency: const MetricRatio.empty(),
        combinedFocusStudySeconds: 0,
        focusStudyOverlapSeconds: 0,
        metricPolicyNumber: MetricPolicyV1.number,
        sourceWatermarkCommitSeq: 0,
        closedDayCount: 0,
        memberDayCount: period.dayKeys.length,
      );

  /// The aggregation window this Insight summarizes.
  final InsightPeriod period;

  /// The applied Life Area filter, or null when unscoped.
  final String? lifeAreaId;

  /// Completed eligible tasks over the range's eligible set, summed across the
  /// contributing daily closes (R-INSIGHT-001).
  final MetricRatio taskCompletion;

  /// Eligible planned tasks incomplete at their day boundaries, summed across
  /// the range. Reported separately from completion (R-INSIGHT-001).
  final int missedCount;

  /// The labeled carried-forward subset of [missedCount]; never double-counted.
  final int carriedCount;

  /// Habit consistency under metric policy v1: completed eligible occurrences
  /// over all eligible (non-paused) occurrences in the range (R-HABIT-007).
  final MetricRatio habitConsistency;

  /// Interval-unioned focus + study time in whole seconds over the window;
  /// overlapping focus/study time is counted once (R-INSIGHT-001, R-FOCUS-005).
  final int combinedFocusStudySeconds;

  /// The focus/study time removed by the interval-union, in whole seconds.
  final int focusStudyOverlapSeconds;

  /// The numeric metric policy the contributing closes were sealed under.
  final int metricPolicyNumber;

  /// The maximum source commit sequence across the contributing daily closes.
  /// The Insight is reproducible from this watermark (R-INSIGHT-004).
  final int sourceWatermarkCommitSeq;

  /// How many of the window's member days had a factual close.
  final int closedDayCount;

  /// How many member days the window spans in total.
  final int memberDayCount;

  /// The displayed metric policy version label, e.g. `metric-policy-v1`.
  String get metricPolicyVersion => MetricPolicyV1.label(metricPolicyNumber);

  /// Whether any member day was closed. A window with no closed days is wholly
  /// "no data" (R-INSIGHT-002).
  bool get hasClosedData => closedDayCount > 0;
}
