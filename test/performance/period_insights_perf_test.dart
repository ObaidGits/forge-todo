import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';

import '../helpers/fake_clock.dart';

/// In-process performance tripwire for the weekly/monthly Insights aggregation
/// (task 10.8, R-INSIGHT-001, NFR-PERF-003).
///
/// The authoritative aggregate/dashboard query budget (p95 ≤100 ms at reference
/// scale) is an external reference-profile campaign; this guard is the
/// automated regression tripwire that complements it. It asserts the
/// close-derived aggregation stays linear in the number of contributing daily
/// closes and that a cache hit reproduces the value without re-aggregating. It
/// never weakens or substitutes for the reference-profile requirement. The
/// suite runs with `--timeout=5x`, so the generous ceiling is not a wall-clock
/// race; only a super-linear regression trips it.
///
/// **Validates: Requirements R-INSIGHT-001, NFR-PERF-003**
void main() {
  const double tripwireMs = 500.0;
  // A full-year window is far larger than any real weekly/monthly period, so a
  // linear aggregation is milliseconds; a quadratic regression would blow up.
  const int dayCount = 366;

  test('[TEST-PERF-INSIGHT-AGG][V1][TASK-10.8][R-INSIGHT-001,NFR-PERF-003] the '
      'period aggregation over many factual closes stays within the tripwire and '
      'a cache hit reproduces the value without re-aggregating', () async {
    final List<String> dayKeys = <String>[
      for (int i = 0; i < dayCount; i += 1)
        LocalDate(2024, 1, 1).addDays(i).iso,
    ];
    final _CountingPlannerSummary summary = _CountingPlannerSummary(
      closes: <PlannerDailyCloseSnapshot>[
        for (int i = 0; i < dayCount; i += 1)
          PlannerDailyCloseSnapshot(
            periodId: 'p$i',
            closedAtUtc: i,
            boundaryUtc: i,
            metricPolicyNumber: 1,
            sourceWatermarkCommitSeq: i + 1,
            tasks: const PlannerTaskCloseTally(
              eligibleCount: 4,
              completedCount: 3,
              missedCount: 1,
              carriedCount: 0,
              eligibleRootHash: 'e',
              completedRootHash: 'c',
            ),
            habits: const <PlannerHabitCloseOutcome>[
              PlannerHabitCloseOutcome(
                occurrenceId: 'o',
                statusWire: 'completed',
              ),
            ],
            adjustmentCount: 0,
          ),
      ],
    );
    final _MapCache cache = _MapCache();
    final PeriodInsightsService insights = PeriodInsightsService(
      plannerSummary: summary,
      combinedTime: CombinedTimeMetricsService(
        focusDuration: _EmptyFocus(),
        studyDuration: _EmptyStudy(),
      ),
      cache: cache,
      clock: FakeClock(initialUtc: DateTime.utc(2024, 12, 31)),
    );

    final InsightPeriod period = InsightPeriod(
      kind: InsightPeriodKind.monthly,
      periodKey: '2024-full',
      timezoneId: 'UTC',
      rangeStartUtc: 0,
      rangeEndUtc: 1000000,
      dayKeys: dayKeys,
    );

    final Stopwatch sw = Stopwatch()..start();
    final PeriodInsight first = await insights.insight(
      ProfileId('p1'),
      period,
      lifeAreaId: LifeAreaId('area-1'),
    );
    sw.stop();
    final double firstMs = sw.elapsedMicroseconds / 1000.0;

    // Correctness: 3 completed of 4 eligible across every closed day.
    expect(first.taskCompletion.numerator, 3 * dayCount);
    expect(first.taskCompletion.denominator, 4 * dayCount);
    expect(first.closedDayCount, dayCount);
    expect(cache.writes, 1);

    // A second read reproduces from cache and does not re-aggregate.
    final PeriodInsight second = await insights.insight(
      ProfileId('p1'),
      period,
      lifeAreaId: LifeAreaId('area-1'),
    );
    expect(second.taskCompletion, first.taskCompletion);
    expect(cache.writes, 1, reason: 'a cache hit must not rewrite the entry');

    expect(
      firstMs,
      lessThan(tripwireMs),
      reason:
          'aggregating $dayCount factual closes took '
          '${firstMs.toStringAsFixed(2)} ms, exceeding ${tripwireMs}ms',
    );
  });
}

final class _CountingPlannerSummary implements PlannerSummaryContract {
  _CountingPlannerSummary({required this.closes});
  final List<PlannerDailyCloseSnapshot> closes;

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async => null;

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async => closes;
}

final class _MapCache implements AggregateCacheStore {
  final Map<String, CachedAggregate> _entries = <String, CachedAggregate>{};
  int writes = 0;

  @override
  Future<CachedAggregate?> read(
    String profileId, {
    required String cacheKey,
  }) async => _entries[cacheKey];

  @override
  Future<void> write(CachedAggregate entry) async {
    writes += 1;
    _entries
      ..removeWhere(
        (String key, CachedAggregate value) =>
            value.metric == entry.metric &&
            value.rangeHash == entry.rangeHash &&
            value.filterHash == entry.filterHash &&
            value.policyVersion == entry.policyVersion,
      )
      ..[entry.cacheKey] = entry;
  }
}

final class _EmptyFocus implements FocusDurationContract {
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => const <TimeSpan>[];
}

final class _EmptyStudy implements StudyDurationContract {
  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => const <TimeSpan>[];
}
