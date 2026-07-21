import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';

/// The period-over-period trend of one metric (R-INSIGHT-002).
///
/// A trend is the current value minus the comparable previous-period value. It
/// is *absent* whenever either period lacks data for the metric, so a
/// comparison against a period with no eligible data never fabricates a
/// misleading delta (R-INSIGHT-002). [delta] is non-null exactly when
/// [present] is true.
final class InsightTrend {
  /// A present trend carrying the current-minus-previous [delta].
  const InsightTrend.of(this.delta) : present = true;

  /// An absent trend: one of the compared periods lacked data.
  const InsightTrend.absent() : delta = null, present = false;

  /// The current-minus-previous difference, or null when [present] is false.
  final double? delta;

  /// Whether both compared periods had data for this metric.
  final bool present;

  /// The trend between two ratio metrics, absent when either has no data.
  factory InsightTrend.betweenRatios(
    MetricRatio current,
    MetricRatio? previous,
  ) {
    final double? c = current.ratio;
    final double? p = previous?.ratio;
    if (c == null || p == null) {
      return const InsightTrend.absent();
    }
    return InsightTrend.of(c - p);
  }

  /// The trend between two second totals, present only when both periods
  /// contributed closed data.
  factory InsightTrend.betweenSeconds({
    required int currentSeconds,
    required int previousSeconds,
    required bool currentHasData,
    required bool previousHasData,
  }) {
    if (!currentHasData || !previousHasData) {
      return const InsightTrend.absent();
    }
    return InsightTrend.of((currentSeconds - previousSeconds).toDouble());
  }
}

/// A weekly/monthly Insight paired with its trend against the comparable
/// previous period (R-INSIGHT-002).
///
/// The [previous] Insight is retained so every trend is explainable: a reader
/// can see both endpoints, not just a bare delta. When there is no previous
/// period (or it had no data) each trend is [InsightTrend.absent].
final class PeriodInsightComparison {
  PeriodInsightComparison({required this.current, this.previous})
    : taskCompletionTrend = InsightTrend.betweenRatios(
        current.taskCompletion,
        previous?.taskCompletion,
      ),
      habitConsistencyTrend = InsightTrend.betweenRatios(
        current.habitConsistency,
        previous?.habitConsistency,
      ),
      combinedTimeTrend = InsightTrend.betweenSeconds(
        currentSeconds: current.combinedFocusStudySeconds,
        previousSeconds: previous?.combinedFocusStudySeconds ?? 0,
        currentHasData: current.hasClosedData,
        previousHasData: previous?.hasClosedData ?? false,
      );

  final PeriodInsight current;
  final PeriodInsight? previous;

  final InsightTrend taskCompletionTrend;
  final InsightTrend habitConsistencyTrend;
  final InsightTrend combinedTimeTrend;
}
