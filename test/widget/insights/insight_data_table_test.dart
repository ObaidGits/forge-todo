import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/presentation/insight_data_table.dart';

void main() {
  InsightPeriod period() => InsightPeriod.weekly(
    LocalDate(2024, 6, 3),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 10,
  );

  PeriodInsight insight({
    MetricRatio? task,
    MetricRatio? habit,
    int combined = 5400,
    int closedDays = 3,
  }) => PeriodInsight(
    period: period(),
    lifeAreaId: 'area-1',
    taskCompletion: task ?? MetricRatio(numerator: 3, denominator: 4),
    missedCount: 1,
    carriedCount: 0,
    habitConsistency: habit ?? MetricRatio(numerator: 1, denominator: 2),
    combinedFocusStudySeconds: combined,
    focusStudyOverlapSeconds: 0,
    metricPolicyNumber: 1,
    sourceWatermarkCommitSeq: 42,
    closedDayCount: closedDays,
    memberDayCount: 7,
  );

  Future<void> pump(WidgetTester tester, PeriodInsightComparison comparison) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: InsightDataTable(comparison: comparison),
            ),
          ),
        ),
      );

  group('[TEST-INSIGHT-TABLE-A11Y][V1][TASK-10.4][R-INSIGHT-003,NFR-A11Y-001] '
      'accessible data-table alternative', () {
    testWidgets('renders a semantic table with every explainable metric', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        PeriodInsightComparison(
          current: insight(),
          previous: insight(
            task: MetricRatio(numerator: 1, denominator: 4),
            habit: MetricRatio(numerator: 1, denominator: 2),
            combined: 1800,
          ),
        ),
      );

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Task completion'), findsOneWidget);
      // The value exposes its numerator/denominator, not an opaque score.
      expect(find.text('75% (3/4)'), findsOneWidget);
      expect(find.text('Habit consistency'), findsOneWidget);
      expect(find.text('Focus + study time'), findsOneWidget);
      expect(find.text('1h 30m (5400s)'), findsOneWidget);
      // A present trend renders with a sign (not conveyed by color alone).
      expect(find.text('+50 pp'), findsOneWidget);
    });

    testWidgets('a zero-denominator metric shows "no data", never 0%', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        PeriodInsightComparison(
          current: insight(
            task: const MetricRatio.empty(),
            habit: const MetricRatio.empty(),
            combined: 0,
            closedDays: 0,
          ),
        ),
      );

      expect(find.text('No data'), findsWidgets);
      expect(find.text('0% (0/0)'), findsNothing);
    });

    testWidgets('an absent trend shows "no comparison"', (
      WidgetTester tester,
    ) async {
      await pump(tester, PeriodInsightComparison(current: insight()));
      expect(find.text('No comparison'), findsWidgets);
    });

    testWidgets('states range, timezone, filter, formula version, and the '
        'paused/skipped and missing-data caveats', (WidgetTester tester) async {
      await pump(tester, PeriodInsightComparison(current: insight()));

      expect(find.textContaining('2024-06-03 – 2024-06-09'), findsOneWidget);
      expect(find.textContaining('UTC'), findsOneWidget);
      expect(find.textContaining('metric-policy-v1'), findsOneWidget);
      expect(
        find.textContaining('Paused occurrences are excluded'),
        findsOneWidget,
      );
      expect(
        find.textContaining('do not contribute to task or habit metrics'),
        findsOneWidget,
      );
    });

    testWidgets('the chart-semantics wrapper reads the metrics for assistive '
        'technology', (WidgetTester tester) async {
      final PeriodInsightComparison comparison = PeriodInsightComparison(
        current: insight(),
      );
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InsightChartSemantics(
              comparison: comparison,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      final data = tester
          .getSemantics(find.byType(InsightChartSemantics))
          .getSemanticsData();
      expect(data.label, contains('Task completion: 75% (3/4)'));
      expect(data.label, contains('Weekly insights'));
      handle.dispose();
    });
  });
}
