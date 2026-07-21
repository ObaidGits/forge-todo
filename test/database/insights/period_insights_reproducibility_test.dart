import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insight_codec.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/infrastructure/drift_aggregate_cache_store.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_summary_repository.dart';

import '../../helpers/fake_clock.dart';
import '../planner/planner_test_support.dart';

final class _FixedFocus implements FocusDurationContract {
  _FixedFocus(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => spans;
}

final class _FixedStudy implements StudyDurationContract {
  _FixedStudy(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => spans;
}

/// Wave 9 risk-gate reproducibility depth for V1 Insights (task 10.8): monthly
/// aggregation reproducibility, deterministic durable-cache reproduction and
/// watermark-driven invalidation at the real `aggregate_cache` layer, and
/// deterministic cache-value serialization (R-INSIGHT-001, R-INSIGHT-004).
void main() {
  late PlannerHarness h;
  late PeriodInsightsService insights;
  late DriftAggregateCacheStore cache;
  const int s = IntervalUnion.microsPerSecond;

  setUp(() async {
    h = await PlannerHarness.open();
    cache = DriftAggregateCacheStore(h.db);
    insights = PeriodInsightsService(
      plannerSummary: PlannerSummaryRepository(h.reads),
      combinedTime: CombinedTimeMetricsService(
        focusDuration: _FixedFocus(<TimeSpan>[
          TimeSpan(startUtc: 0, endUtc: 3600 * s),
        ]),
        studyDuration: _FixedStudy(<TimeSpan>[
          TimeSpan(startUtc: 1800 * s, endUtc: 5400 * s),
        ]),
      ),
      cache: cache,
      clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 10, 12)),
    );
  });

  tearDown(() async {
    await h.close();
  });

  Future<PlanningPeriod> saveDay(String key) async {
    await h.service.savePlanningRecord(
      commandId: h.nextCommandId('save-$key'),
      profileId: h.profileId,
      input: SavePlanningRecordInput(
        lifeAreaId: h.lifeAreaId.value,
        kind: PlanningPeriodKind.day,
        periodKey: key,
        dailyPlanMd: SectionEdit.set('plan $key'),
      ),
    );
    return (await h.reads.findByKey(
      h.profileId,
      lifeAreaId: h.lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: key,
    ))!;
  }

  Future<void> closeDay(
    String key, {
    required String closeSeed,
    required int boundaryUtc,
    List<CloseTaskInput> tasks = const <CloseTaskInput>[],
  }) async {
    final PlanningPeriod day = await saveDay(key);
    await h.service.closePeriod(
      commandId: h.nextCommandId(closeSeed),
      profileId: h.profileId,
      input: ClosePeriodInput(
        periodId: day.id.value,
        boundaryUtc: boundaryUtc,
        metricPolicyVersion: 1,
        tasks: tasks,
      ),
    );
  }

  // June 2024 monthly window.
  InsightPeriod monthly() => InsightPeriod.monthly(
    LocalDate(2024, 6, 15),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 100000 * s,
  );

  CloseTaskInput doneTask(String id) => CloseTaskInput(
    taskId: id,
    isPlanned: true,
    isDue: true,
    completedAtOrBeforeBoundary: true,
  );

  test('[TEST-DB-INSIGHT-MONTHLY-REPRO][V1][TASK-10.8][R-INSIGHT-001,'
      'R-INSIGHT-004] a monthly Insight aggregates its factual daily closes '
      'and reproduces the identical value on a second read', () async {
    await closeDay(
      '2024-06-03',
      closeSeed: 'm1',
      boundaryUtc: 1,
      tasks: <CloseTaskInput>[doneTask('a')],
    );
    await closeDay(
      '2024-06-20',
      closeSeed: 'm2',
      boundaryUtc: 1,
      tasks: <CloseTaskInput>[doneTask('b')],
    );

    final PeriodInsight first = await insights.insight(
      h.profileId,
      monthly(),
      lifeAreaId: h.lifeAreaId,
    );
    expect(first.taskCompletion, MetricRatio(numerator: 2, denominator: 2));
    expect(first.closedDayCount, 2);
    expect(first.metricPolicyVersion, 'metric-policy-v1');

    // Exactly one durable cache row exists for the window.
    final int cachedRows = await h.db
        .customSelect('SELECT COUNT(*) AS c FROM aggregate_cache')
        .map((row) => row.read<int>('c'))
        .getSingle();
    expect(cachedRows, 1);

    final PeriodInsight second = await insights.insight(
      h.profileId,
      monthly(),
      lifeAreaId: h.lifeAreaId,
    );
    expect(second.taskCompletion, first.taskCompletion);
    expect(second.sourceWatermarkCommitSeq, first.sourceWatermarkCommitSeq);
  });

  test('[TEST-DB-INSIGHT-WATERMARK-INVALIDATE][V1][TASK-10.8][R-INSIGHT-004] '
      'a new factual close advances the watermark, recomputes the metric, and '
      'keeps exactly one live cache entry for the window', () async {
    await closeDay(
      '2024-06-03',
      closeSeed: 'w1',
      boundaryUtc: 1,
      tasks: <CloseTaskInput>[doneTask('a')],
    );
    final PeriodInsight before = await insights.insight(
      h.profileId,
      monthly(),
      lifeAreaId: h.lifeAreaId,
    );
    expect(before.taskCompletion, MetricRatio(numerator: 1, denominator: 1));
    final int firstWatermark = before.sourceWatermarkCommitSeq;

    // A later day closes with an incomplete eligible task, advancing the
    // source watermark and changing the aggregate.
    await closeDay(
      '2024-06-21',
      closeSeed: 'w2',
      boundaryUtc: 1,
      tasks: const <CloseTaskInput>[
        CloseTaskInput(
          taskId: 'b',
          isPlanned: true,
          isDue: true,
          completedAtOrBeforeBoundary: false,
        ),
      ],
    );

    final PeriodInsight after = await insights.insight(
      h.profileId,
      monthly(),
      lifeAreaId: h.lifeAreaId,
    );
    // 1 completed of 2 eligible now; watermark advanced.
    expect(after.taskCompletion, MetricRatio(numerator: 1, denominator: 2));
    expect(after.sourceWatermarkCommitSeq, greaterThan(firstWatermark));

    // The superseded cache entry was replaced: exactly one live row remains.
    final int cachedRows = await h.db
        .customSelect('SELECT COUNT(*) AS c FROM aggregate_cache')
        .map((row) => row.read<int>('c'))
        .getSingle();
    expect(cachedRows, 1);
  });

  test(
    '[TEST-INSIGHT-CODEC-DETERMINISTIC][V1][TASK-10.8][R-INSIGHT-004] the '
    'cached-metrics serialization is deterministic and round-trips exactly',
    () {
      final CachedPeriodMetrics metrics = CachedPeriodMetrics(
        taskCompletion: MetricRatio(numerator: 5, denominator: 8),
        missedCount: 3,
        carriedCount: 2,
        habitConsistency: MetricRatio(numerator: 4, denominator: 7),
        metricPolicyNumber: 1,
        sourceWatermarkCommitSeq: 4242,
        closedDayCount: 6,
      );

      final String a = PeriodInsightCodec.encode(metrics);
      final String b = PeriodInsightCodec.encode(metrics);
      // Deterministic: the same metrics always serialize identically.
      expect(a, b);

      final CachedPeriodMetrics restored = PeriodInsightCodec.decode(a);
      expect(restored.taskCompletion, metrics.taskCompletion);
      expect(restored.habitConsistency, metrics.habitConsistency);
      expect(restored.missedCount, metrics.missedCount);
      expect(restored.carriedCount, metrics.carriedCount);
      expect(restored.metricPolicyNumber, metrics.metricPolicyNumber);
      expect(
        restored.sourceWatermarkCommitSeq,
        metrics.sourceWatermarkCommitSeq,
      );
      expect(restored.closedDayCount, metrics.closedDayCount);
      // Re-encoding the round-tripped value reproduces identical bytes.
      expect(PeriodInsightCodec.encode(restored), a);
    },
  );
}
