import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/presentation/insight_data_table.dart';

/// Wave 9 risk-gate accessibility depth for the Insights table alternative
/// (task 10.8), covering the NFR-A11Y-003 aspects beyond the 10.4 semantics
/// test: header roles, column-header labels, and that trend direction is
/// conveyed by a text sign — never color alone (R-INSIGHT-003, NFR-A11Y-003).
void main() {
  InsightPeriod period() => InsightPeriod.weekly(
    LocalDate(2024, 6, 3),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 10,
  );

  PeriodInsight insight({required MetricRatio task}) => PeriodInsight(
    period: period(),
    lifeAreaId: 'area-1',
    taskCompletion: task,
    missedCount: 1,
    carriedCount: 0,
    habitConsistency: MetricRatio(numerator: 1, denominator: 2),
    combinedFocusStudySeconds: 5400,
    focusStudyOverlapSeconds: 0,
    metricPolicyNumber: 1,
    sourceWatermarkCommitSeq: 42,
    closedDayCount: 3,
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

  group('[TEST-INSIGHT-A11Y-DEPTH][V1][TASK-10.8][R-INSIGHT-003,NFR-A11Y-003] '
      'accessible-table roles and non-color trend', () {
    testWidgets('exposes the metric/value/trend column headers as labels', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        PeriodInsightComparison(
          current: insight(task: MetricRatio(numerator: 3, denominator: 4)),
        ),
      );
      // The three column headers are present as navigable text.
      expect(find.text('Metric'), findsOneWidget);
      expect(find.text('Value'), findsOneWidget);
      expect(find.text('Trend'), findsOneWidget);
      // One DataRow per explainable metric (task, habit, time, missed, carried).
      final DataTable table = tester.widget<DataTable>(
        find.byKey(const ValueKey<String>('insight-table')),
      );
      expect(table.rows.length, 5);
    });

    testWidgets('the title carries a header semantics role', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pump(
        tester,
        PeriodInsightComparison(
          current: insight(task: MetricRatio(numerator: 3, denominator: 4)),
        ),
      );
      // The title text is exposed to assistive technology with the header role.
      final data = tester
          .getSemantics(find.text('Weekly insights'))
          .getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets(
      'a declining trend is shown with a minus sign, not color alone',
      (WidgetTester tester) async {
        // current 25% vs previous 75% => -50 pp.
        await pump(
          tester,
          PeriodInsightComparison(
            current: insight(task: MetricRatio(numerator: 1, denominator: 4)),
            previous: insight(task: MetricRatio(numerator: 3, denominator: 4)),
          ),
        );
        expect(find.text('-50 pp'), findsOneWidget);
      },
    );

    testWidgets('an improving trend is shown with a plus sign', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        PeriodInsightComparison(
          current: insight(task: MetricRatio(numerator: 3, denominator: 4)),
          previous: insight(task: MetricRatio(numerator: 1, denominator: 4)),
        ),
      );
      expect(find.text('+50 pp'), findsOneWidget);
    });
  });
}
