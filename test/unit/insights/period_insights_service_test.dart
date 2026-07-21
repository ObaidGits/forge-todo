import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';

import '../../helpers/fake_clock.dart';

/// A fake planner contract keyed by day key, returning only closed days.
final class _FakePlanner implements PlannerSummaryContract {
  _FakePlanner(this.closesByDay);

  final Map<String, PlannerDailyCloseSnapshot> closesByDay;

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async => closesByDay[dayKey];

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async => <PlannerDailyCloseSnapshot>[
    for (final String key in dayKeys)
      if (closesByDay[key] != null) closesByDay[key]!,
  ];
}

final class _FakeFocus implements FocusDurationContract {
  _FakeFocus(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => spans;
}

final class _FakeStudy implements StudyDurationContract {
  _FakeStudy(this.spans);
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

/// An in-memory cache that records reads, writes, and deletes so tests can
/// assert cache-hit and invalidation behavior.
final class _FakeCache implements AggregateCacheStore {
  final Map<String, CachedAggregate> _rows = <String, CachedAggregate>{};
  int reads = 0;
  int writes = 0;

  String _pk(String profileId, String cacheKey) => '$profileId::$cacheKey';

  @override
  Future<CachedAggregate?> read(
    String profileId, {
    required String cacheKey,
  }) async {
    reads += 1;
    return _rows[_pk(profileId, cacheKey)];
  }

  @override
  Future<void> write(CachedAggregate entry) async {
    writes += 1;
    // Mirror the durable store's supersede-then-upsert invalidation.
    _rows.removeWhere(
      (String key, CachedAggregate row) =>
          row.profileId == entry.profileId &&
          row.metric == entry.metric &&
          row.rangeHash == entry.rangeHash &&
          row.filterHash == entry.filterHash &&
          row.policyVersion == entry.policyVersion &&
          row.cacheKey != entry.cacheKey,
    );
    _rows[_pk(entry.profileId, entry.cacheKey)] = entry;
  }

  int get size => _rows.length;
}

void main() {
  final ProfileId profile = ProfileId('profile-1');
  final LifeAreaId area = LifeAreaId('area-1');
  const int s = IntervalUnion.microsPerSecond;

  TimeSpan span(int startSec, int endSec) =>
      TimeSpan(startUtc: startSec * s, endUtc: endSec * s);

  PlannerDailyCloseSnapshot day({
    required String periodId,
    int eligible = 2,
    int completed = 1,
    int missed = 1,
    int carried = 0,
    List<PlannerHabitCloseOutcome> habits = const <PlannerHabitCloseOutcome>[],
    int watermark = 100,
    int policy = 1,
  }) => PlannerDailyCloseSnapshot(
    periodId: periodId,
    closedAtUtc: 2000,
    boundaryUtc: 1500,
    metricPolicyNumber: policy,
    sourceWatermarkCommitSeq: watermark,
    tasks: PlannerTaskCloseTally(
      eligibleCount: eligible,
      completedCount: completed,
      missedCount: missed,
      carriedCount: carried,
      eligibleRootHash: 'e-$periodId',
      completedRootHash: 'c-$periodId',
    ),
    habits: habits,
    adjustmentCount: 0,
  );

  PeriodInsightsService serviceWith(
    Map<String, PlannerDailyCloseSnapshot> closes, {
    List<TimeSpan> focus = const <TimeSpan>[],
    List<TimeSpan> study = const <TimeSpan>[],
    _FakeCache? cache,
  }) => PeriodInsightsService(
    plannerSummary: _FakePlanner(closes),
    combinedTime: CombinedTimeMetricsService(
      focusDuration: _FakeFocus(focus),
      studyDuration: _FakeStudy(study),
    ),
    cache: cache ?? _FakeCache(),
    clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 3, 12)),
  );

  // A Monday-anchored week: 2024-06-03 .. 2024-06-09.
  InsightPeriod weekly() => InsightPeriod.weekly(
    LocalDate(2024, 6, 3),
    timezoneId: 'UTC',
    rangeStartUtc: 0,
    rangeEndUtc: 100000 * s,
  );

  group('[TEST-INSIGHT-PERIOD-AGG][V1][TASK-10.4][R-INSIGHT-001] weekly/monthly '
      'aggregation', () {
    test('weekly task completion sums eligible/completed across closed '
        'days', () async {
      final PeriodInsightsService
      service = serviceWith(<String, PlannerDailyCloseSnapshot>{
        '2024-06-03': day(periodId: 'p1', eligible: 3, completed: 2, missed: 1),
        '2024-06-05': day(periodId: 'p2', eligible: 2, completed: 2, missed: 0),
      });

      final PeriodInsight insight = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );

      // 4 completed of 5 eligible across the two closed days.
      expect(insight.taskCompletion.numerator, 4);
      expect(insight.taskCompletion.denominator, 5);
      expect(insight.missedCount, 1);
      expect(insight.closedDayCount, 2);
      expect(insight.memberDayCount, 7);
      expect(insight.metricPolicyVersion, 'metric-policy-v1');
    });

    test('habit consistency excludes paused and keeps a skip in the '
        'denominator only', () async {
      final PeriodInsightsService
      service = serviceWith(<String, PlannerDailyCloseSnapshot>{
        '2024-06-03': day(
          periodId: 'p1',
          habits: const <PlannerHabitCloseOutcome>[
            PlannerHabitCloseOutcome(
              occurrenceId: 'h1',
              statusWire: 'completed',
            ),
            PlannerHabitCloseOutcome(occurrenceId: 'h2', statusWire: 'skipped'),
            PlannerHabitCloseOutcome(occurrenceId: 'h3', statusWire: 'paused'),
          ],
        ),
        '2024-06-04': day(
          periodId: 'p2',
          habits: const <PlannerHabitCloseOutcome>[
            PlannerHabitCloseOutcome(
              occurrenceId: 'h4',
              statusWire: 'completed',
            ),
            PlannerHabitCloseOutcome(occurrenceId: 'h5', statusWire: 'missed'),
          ],
        ),
      });

      final PeriodInsight insight = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );

      // Eligible = completed(2) + skipped(1) + missed(1) = 4; paused excluded.
      expect(insight.habitConsistency.numerator, 2);
      expect(insight.habitConsistency.denominator, 4);
    });

    test('focus and study time is interval-unioned over the window', () async {
      final PeriodInsightsService service = serviceWith(
        <String, PlannerDailyCloseSnapshot>{'2024-06-03': day(periodId: 'p1')},
        focus: <TimeSpan>[span(0, 3600)],
        study: <TimeSpan>[span(1800, 5400)],
      );

      final PeriodInsight insight = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );

      expect(insight.combinedFocusStudySeconds, 5400);
      expect(insight.focusStudyOverlapSeconds, 1800);
    });

    test('the watermark is the maximum contributing close watermark', () async {
      final PeriodInsightsService service =
          serviceWith(<String, PlannerDailyCloseSnapshot>{
            '2024-06-03': day(periodId: 'p1', watermark: 120),
            '2024-06-06': day(periodId: 'p2', watermark: 305),
          });

      final PeriodInsight insight = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      expect(insight.sourceWatermarkCommitSeq, 305);
    });
  });

  group(
    '[TEST-INSIGHT-PERIOD-ZERO-DATA][V1][TASK-10.4][R-INSIGHT-002] zero-data',
    () {
      test('a window with no closed days is no-data, not 0%', () async {
        final PeriodInsightsService service = serviceWith(
          const <String, PlannerDailyCloseSnapshot>{},
        );

        final PeriodInsight insight = await service.insight(
          profile,
          weekly(),
          lifeAreaId: area,
        );

        expect(insight.hasClosedData, isFalse);
        expect(insight.taskCompletion.hasData, isFalse);
        expect(insight.taskCompletion.ratio, isNull);
        expect(insight.habitConsistency.hasData, isFalse);
        expect(insight.closedDayCount, 0);
      });

      test(
        'focus/study time is still reported when no day is closed',
        () async {
          final PeriodInsightsService service = serviceWith(
            const <String, PlannerDailyCloseSnapshot>{},
            focus: <TimeSpan>[span(0, 600)],
          );

          final PeriodInsight insight = await service.insight(
            profile,
            weekly(),
            lifeAreaId: area,
          );
          expect(insight.combinedFocusStudySeconds, 600);
          expect(insight.hasClosedData, isFalse);
        },
      );
    },
  );

  group('[TEST-INSIGHT-PERIOD-TREND][V1][TASK-10.4][R-INSIGHT-002] trend', () {
    test('trend is current minus previous when both have data', () async {
      final PeriodInsightsService service = serviceWith(
        const <String, PlannerDailyCloseSnapshot>{},
      );
      final PeriodInsight current = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      // Build two explicit insights to compare deterministically.
      final PeriodInsight high = PeriodInsight(
        period: current.period,
        lifeAreaId: area.value,
        taskCompletion: MetricRatio(numerator: 3, denominator: 4),
        missedCount: 1,
        carriedCount: 0,
        habitConsistency: MetricRatio(numerator: 1, denominator: 2),
        combinedFocusStudySeconds: 3600,
        focusStudyOverlapSeconds: 0,
        metricPolicyNumber: 1,
        sourceWatermarkCommitSeq: 10,
        closedDayCount: 3,
        memberDayCount: 7,
      );
      final PeriodInsight low = PeriodInsight(
        period: current.period,
        lifeAreaId: area.value,
        taskCompletion: MetricRatio(numerator: 1, denominator: 4),
        missedCount: 3,
        carriedCount: 0,
        habitConsistency: MetricRatio(numerator: 0, denominator: 2),
        combinedFocusStudySeconds: 1800,
        focusStudyOverlapSeconds: 0,
        metricPolicyNumber: 1,
        sourceWatermarkCommitSeq: 5,
        closedDayCount: 2,
        memberDayCount: 7,
      );

      final PeriodInsightComparison c = service.compare(high, previous: low);
      expect(c.taskCompletionTrend.present, isTrue);
      expect(c.taskCompletionTrend.delta, closeTo(0.5, 1e-9));
      expect(c.combinedTimeTrend.present, isTrue);
      expect(c.combinedTimeTrend.delta, 1800);
    });

    test('trend is absent when the previous period lacks data', () async {
      final PeriodInsightsService service = serviceWith(
        const <String, PlannerDailyCloseSnapshot>{},
      );
      final PeriodInsight current = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      final PeriodInsight withData = PeriodInsight(
        period: current.period,
        lifeAreaId: area.value,
        taskCompletion: MetricRatio(numerator: 2, denominator: 4),
        missedCount: 2,
        carriedCount: 0,
        habitConsistency: MetricRatio(numerator: 1, denominator: 2),
        combinedFocusStudySeconds: 3600,
        focusStudyOverlapSeconds: 0,
        metricPolicyNumber: 1,
        sourceWatermarkCommitSeq: 9,
        closedDayCount: 2,
        memberDayCount: 7,
      );

      // Previous is the zero-data insight (no closed days).
      final PeriodInsightComparison c = service.compare(
        withData,
        previous: current,
      );
      expect(c.taskCompletionTrend.present, isFalse);
      expect(c.taskCompletionTrend.delta, isNull);
      expect(c.combinedTimeTrend.present, isFalse);
    });
  });

  group('[TEST-INSIGHT-PERIOD-CACHE][V1][TASK-10.4][R-INSIGHT-004] cache '
      'determinism and invalidation', () {
    test('a second read at the same watermark hits the cache and does not '
        'rewrite it', () async {
      final _FakeCache cache = _FakeCache();
      final PeriodInsightsService service = serviceWith(
        <String, PlannerDailyCloseSnapshot>{
          '2024-06-03': day(periodId: 'p1', eligible: 4, completed: 3),
        },
        cache: cache,
      );

      final PeriodInsight first = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      expect(cache.writes, 1);

      final PeriodInsight second = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      // The cached close-derived metrics are reproduced identically.
      expect(second.taskCompletion, first.taskCompletion);
      expect(second.sourceWatermarkCommitSeq, first.sourceWatermarkCommitSeq);
      // No new write: the watermark was unchanged, so the cache was honored.
      expect(cache.writes, 1);
      expect(cache.size, 1);
    });

    test('a changed source watermark invalidates and recomputes, keeping one '
        'live entry', () async {
      final Map<String, PlannerDailyCloseSnapshot> closes =
          <String, PlannerDailyCloseSnapshot>{
            '2024-06-03': day(
              periodId: 'p1',
              eligible: 4,
              completed: 2,
              watermark: 100,
            ),
          };
      final _FakeCache cache = _FakeCache();
      final PeriodInsightsService service = serviceWith(closes, cache: cache);

      final PeriodInsight before = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      expect(before.taskCompletion.numerator, 2);
      expect(cache.writes, 1);

      // A source correction advances the watermark and the sealed counts.
      closes['2024-06-03'] = day(
        periodId: 'p1',
        eligible: 4,
        completed: 4,
        watermark: 250,
      );

      final PeriodInsight after = await service.insight(
        profile,
        weekly(),
        lifeAreaId: area,
      );
      expect(after.taskCompletion.numerator, 4);
      expect(after.sourceWatermarkCommitSeq, 250);
      // Recomputed and rewritten, and the superseded entry was purged.
      expect(cache.writes, 2);
      expect(cache.size, 1);
    });
  });
}
