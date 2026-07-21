import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/infrastructure/drift_aggregate_cache_store.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_summary_repository.dart';

import '../../helpers/fake_clock.dart';
import '../planner/planner_test_support.dart';

/// Fixed focus/study contracts so the interval-union is deterministic.
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

/// V1 weekly/monthly Insights composed over a real Drift-backed set of
/// immutable factual daily closes, proving aggregation, watermark
/// reproducibility, and durable-cache determinism (R-INSIGHT-001,
/// R-INSIGHT-004).
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
    List<CloseHabitInput> habits = const <CloseHabitInput>[],
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
        habits: habits,
      ),
    );
  }

  // Monday-anchored week 2024-06-03 .. 2024-06-09.
  InsightPeriod weekly() => InsightPeriod.weekly(
    LocalDate(2024, 6, 3),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 100000 * s,
  );

  test('[TEST-DB-INSIGHT-WEEKLY][V1][TASK-10.4][R-INSIGHT-001] '
      'a weekly Insight aggregates the factual daily closes', () async {
    await closeDay(
      '2024-06-03',
      closeSeed: 'c1',
      boundaryUtc: 1,
      tasks: const <CloseTaskInput>[
        CloseTaskInput(
          taskId: 'a',
          isPlanned: true,
          isDue: true,
          completedAtOrBeforeBoundary: true,
        ),
        CloseTaskInput(
          taskId: 'b',
          isPlanned: true,
          isDue: false,
          completedAtOrBeforeBoundary: false,
        ),
      ],
      habits: const <CloseHabitInput>[
        CloseHabitInput(occurrenceId: 'o1', status: 'completed'),
        CloseHabitInput(occurrenceId: 'o2', status: 'paused'),
      ],
    );
    await closeDay(
      '2024-06-05',
      closeSeed: 'c2',
      boundaryUtc: 1,
      tasks: const <CloseTaskInput>[
        CloseTaskInput(
          taskId: 'c',
          isPlanned: true,
          isDue: true,
          completedAtOrBeforeBoundary: true,
        ),
      ],
      habits: const <CloseHabitInput>[
        CloseHabitInput(occurrenceId: 'o3', status: 'skipped'),
      ],
    );

    final PeriodInsight insight = await insights.insight(
      h.profileId,
      weekly(),
      lifeAreaId: h.lifeAreaId,
    );

    // Tasks: 2 completed of 3 eligible across the two closed days.
    expect(insight.taskCompletion.numerator, 2);
    expect(insight.taskCompletion.denominator, 3);
    expect(insight.missedCount, 1);
    // Habits: completed(1) over eligible completed(1)+skipped(1)=2; paused out.
    expect(insight.habitConsistency.numerator, 1);
    expect(insight.habitConsistency.denominator, 2);
    // Interval-unioned focus/study over the window.
    expect(insight.combinedFocusStudySeconds, 5400);
    expect(insight.closedDayCount, 2);
    expect(insight.metricPolicyVersion, 'metric-policy-v1');
  });

  test('[TEST-DB-INSIGHT-ZERO-DATA][V1][TASK-10.4][R-INSIGHT-002] '
      'an un-closed week is no-data, not 0%', () async {
    final PeriodInsight insight = await insights.insight(
      h.profileId,
      weekly(),
      lifeAreaId: h.lifeAreaId,
    );
    expect(insight.hasClosedData, isFalse);
    expect(insight.taskCompletion.hasData, isFalse);
    expect(insight.taskCompletion.ratio, isNull);
  });

  test('[TEST-DB-INSIGHT-CACHE-REPRODUCIBLE][V1][TASK-10.4][R-INSIGHT-004] '
      'the cache reproduces the same value from the same watermark and is '
      'durable', () async {
    await closeDay(
      '2024-06-04',
      closeSeed: 'c1',
      boundaryUtc: 1,
      tasks: const <CloseTaskInput>[
        CloseTaskInput(
          taskId: 'a',
          isPlanned: true,
          isDue: true,
          completedAtOrBeforeBoundary: true,
        ),
      ],
    );

    final PeriodInsight first = await insights.insight(
      h.profileId,
      weekly(),
      lifeAreaId: h.lifeAreaId,
    );

    // A durable cache row now exists and is keyed by the source watermark.
    final int cachedRows = await h.db
        .customSelect('SELECT COUNT(*) AS c FROM aggregate_cache')
        .map((row) => row.read<int>('c'))
        .getSingle();
    expect(cachedRows, 1);

    // A second computation reproduces the same close-derived metrics.
    final PeriodInsight second = await insights.insight(
      h.profileId,
      weekly(),
      lifeAreaId: h.lifeAreaId,
    );
    expect(second.taskCompletion, first.taskCompletion);
    expect(second.sourceWatermarkCommitSeq, first.sourceWatermarkCommitSeq);
    expect(second.metricPolicyVersion, 'metric-policy-v1');
  });
}
