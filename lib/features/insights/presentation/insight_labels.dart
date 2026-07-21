import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';

/// Localization-agnostic display strings for the Insights surfaces.
///
/// The widgets take their copy from an [InsightLabels] instance so the
/// presentation stays free of any specific localization binding and remains
/// directly testable. Callers may supply localized strings; [InsightLabels.en]
/// provides an English fallback. Every value is rendered as text, never color
/// alone (R-INSIGHT-003).
final class InsightLabels {
  const InsightLabels({
    required this.weeklyTitle,
    required this.monthlyTitle,
    required this.metricColumn,
    required this.valueColumn,
    required this.trendColumn,
    required this.taskCompletion,
    required this.habitConsistency,
    required this.combinedTime,
    required this.missed,
    required this.carried,
    required this.noData,
    required this.noComparison,
    required this.pausedSkippedNote,
    required this.missingDataCaveat,
  });

  final String weeklyTitle;
  final String monthlyTitle;
  final String metricColumn;
  final String valueColumn;
  final String trendColumn;
  final String taskCompletion;
  final String habitConsistency;
  final String combinedTime;
  final String missed;
  final String carried;

  /// Shown when a metric has a zero denominator: "no data", never 0%
  /// (R-INSIGHT-002).
  final String noData;

  /// Shown for a trend when a comparable previous period lacked data
  /// (R-INSIGHT-002).
  final String noComparison;
  final String pausedSkippedNote;
  final String missingDataCaveat;

  static const InsightLabels en = InsightLabels(
    weeklyTitle: 'Weekly insights',
    monthlyTitle: 'Monthly insights',
    metricColumn: 'Metric',
    valueColumn: 'Value',
    trendColumn: 'Trend',
    taskCompletion: 'Task completion',
    habitConsistency: 'Habit consistency',
    combinedTime: 'Focus + study time',
    missed: 'Missed tasks',
    carried: 'Carried forward',
    noData: 'No data',
    noComparison: 'No comparison',
    pausedSkippedNote:
        'Paused occurrences are excluded; skipped occurrences stay in the '
        'denominator but not the numerator.',
    missingDataCaveat:
        'Days without a factual close do not contribute to task or habit '
        'metrics.',
  );

  String titleFor(InsightPeriodKind kind) => switch (kind) {
    InsightPeriodKind.weekly => weeklyTitle,
    InsightPeriodKind.monthly => monthlyTitle,
  };
}

/// A single accessible table row: an explainable metric with its value and
/// trend rendered as plain text (R-INSIGHT-003, R-INSIGHT-005).
final class InsightRow {
  const InsightRow({
    required this.label,
    required this.value,
    required this.trend,
    required this.hasData,
  });

  final String label;
  final String value;
  final String trend;

  /// Whether the metric had eligible data. A false value means the [value] is
  /// the "no data" string, not a computed 0%.
  final bool hasData;

  /// A single-string semantic reading of the whole row.
  String get semanticLabel => '$label: $value, $trend';
}

/// Pure formatting for Insight display, independent of Flutter (R-INSIGHT-002,
/// R-INSIGHT-003, R-INSIGHT-005).
abstract final class InsightFormat {
  /// A ratio as a rounded percentage with its explaining numerator/denominator,
  /// or the "no data" label when the denominator is zero (R-INSIGHT-002).
  static String ratio(MetricRatio ratio, InsightLabels labels) {
    final double? value = ratio.ratio;
    if (value == null) {
      return labels.noData;
    }
    final int percent = (value * 100).round();
    return '$percent% (${ratio.numerator}/${ratio.denominator})';
  }

  /// A whole-second duration as `Hh Mm` with the underlying seconds exposed so
  /// the figure is explainable, never opaque (R-INSIGHT-005).
  static String duration(int seconds) {
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final String hm = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
    return '$hm (${seconds}s)';
  }

  /// A ratio trend as signed percentage points, or the "no comparison" label
  /// when either compared period lacked data (R-INSIGHT-002).
  static String ratioTrend(InsightTrend trend, InsightLabels labels) {
    final double? delta = trend.delta;
    if (delta == null) {
      return labels.noComparison;
    }
    final int points = (delta * 100).round();
    return '${_sign(points)}$points pp';
  }

  /// A seconds trend as a signed `Hh Mm` delta, or the "no comparison" label.
  static String secondsTrend(InsightTrend trend, InsightLabels labels) {
    final double? delta = trend.delta;
    if (delta == null) {
      return labels.noComparison;
    }
    final int seconds = delta.round();
    final int magnitude = seconds.abs();
    final int hours = magnitude ~/ 3600;
    final int minutes = (magnitude % 3600) ~/ 60;
    final String hm = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
    return '${_signWord(seconds)}$hm';
  }

  static String _sign(int value) => value > 0 ? '+' : '';

  static String _signWord(int value) =>
      value < 0 ? '-' : (value > 0 ? '+' : '');

  /// The ordered table rows for a comparison (R-INSIGHT-002, R-INSIGHT-003).
  static List<InsightRow> rows(
    PeriodInsightComparison comparison,
    InsightLabels labels,
  ) {
    final PeriodInsight c = comparison.current;
    return <InsightRow>[
      InsightRow(
        label: labels.taskCompletion,
        value: ratio(c.taskCompletion, labels),
        trend: ratioTrend(comparison.taskCompletionTrend, labels),
        hasData: c.taskCompletion.hasData,
      ),
      InsightRow(
        label: labels.habitConsistency,
        value: ratio(c.habitConsistency, labels),
        trend: ratioTrend(comparison.habitConsistencyTrend, labels),
        hasData: c.habitConsistency.hasData,
      ),
      InsightRow(
        label: labels.combinedTime,
        value: duration(c.combinedFocusStudySeconds),
        trend: secondsTrend(comparison.combinedTimeTrend, labels),
        hasData: c.hasClosedData,
      ),
      InsightRow(
        label: labels.missed,
        value: '${c.missedCount}',
        trend: labels.noComparison,
        hasData: c.hasClosedData,
      ),
      InsightRow(
        label: labels.carried,
        value: '${c.carriedCount}',
        trend: labels.noComparison,
        hasData: c.hasClosedData,
      ),
    ];
  }

  /// The caption line stating range, timezone, filter, and formula version
  /// (R-INSIGHT-002).
  static String caption(PeriodInsight insight) {
    final InsightPeriod p = insight.period;
    final String first = p.dayKeys.first;
    final String last = p.dayKeys.last;
    final String filter = insight.lifeAreaId == null
        ? 'all areas'
        : 'area ${insight.lifeAreaId}';
    return '$first – $last · ${p.timezoneId} · $filter · '
        '${insight.metricPolicyVersion}';
  }
}
