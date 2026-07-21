import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/presentation/insight_labels.dart';

void main() {
  const InsightLabels labels = InsightLabels.en;

  InsightPeriod period() => InsightPeriod.weekly(
    LocalDate(2024, 6, 3),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 10,
  );

  PeriodInsight insight({
    MetricRatio? task,
    MetricRatio? habit,
    int combined = 0,
    int closedDays = 3,
  }) => PeriodInsight(
    period: period(),
    lifeAreaId: 'area-1',
    taskCompletion: task ?? MetricRatio(numerator: 3, denominator: 4),
    missedCount: 1,
    carriedCount: 1,
    habitConsistency: habit ?? MetricRatio(numerator: 1, denominator: 2),
    combinedFocusStudySeconds: combined,
    focusStudyOverlapSeconds: 0,
    metricPolicyNumber: 1,
    sourceWatermarkCommitSeq: 42,
    closedDayCount: closedDays,
    memberDayCount: 7,
  );

  group('[TEST-INSIGHT-FORMAT][V1][TASK-10.4][R-INSIGHT-002,R-INSIGHT-005] '
      'explainable formatting', () {
    test('a ratio shows a percentage and its numerator/denominator', () {
      expect(
        InsightFormat.ratio(MetricRatio(numerator: 3, denominator: 4), labels),
        '75% (3/4)',
      );
    });

    test('a zero-denominator ratio shows "no data", never 0%', () {
      expect(
        InsightFormat.ratio(const MetricRatio.empty(), labels),
        labels.noData,
      );
    });

    test('a duration exposes the underlying seconds', () {
      expect(InsightFormat.duration(5400), '1h 30m (5400s)');
      expect(InsightFormat.duration(600), '10m (600s)');
    });

    test('a ratio trend is signed percentage points', () {
      expect(
        InsightFormat.ratioTrend(const InsightTrend.of(0.25), labels),
        '+25 pp',
      );
      expect(
        InsightFormat.ratioTrend(const InsightTrend.of(-0.1), labels),
        '-10 pp',
      );
    });

    test('an absent trend shows "no comparison"', () {
      expect(
        InsightFormat.ratioTrend(const InsightTrend.absent(), labels),
        labels.noComparison,
      );
      expect(
        InsightFormat.secondsTrend(const InsightTrend.absent(), labels),
        labels.noComparison,
      );
    });

    test('rows expose no-data honestly for empty metrics', () {
      final PeriodInsightComparison comparison = PeriodInsightComparison(
        current: insight(
          task: const MetricRatio.empty(),
          habit: const MetricRatio.empty(),
          closedDays: 0,
        ),
      );
      final List<InsightRow> rows = InsightFormat.rows(comparison, labels);
      final InsightRow taskRow = rows.first;
      expect(taskRow.label, labels.taskCompletion);
      expect(taskRow.value, labels.noData);
      expect(taskRow.hasData, isFalse);
    });

    test('the caption states range, timezone, filter, and formula version', () {
      final String caption = InsightFormat.caption(insight());
      expect(caption, contains('2024-06-03'));
      expect(caption, contains('2024-06-09'));
      expect(caption, contains('UTC'));
      expect(caption, contains('area area-1'));
      expect(caption, contains('metric-policy-v1'));
    });
  });
}
