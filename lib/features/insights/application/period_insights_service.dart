import 'dart:math' as math;

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insight_codec.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';

/// Computes V1 weekly and monthly Insights by aggregating the immutable factual
/// daily closes over a window and unioning focus/study time (R-INSIGHT-001,
/// R-INSIGHT-002, R-INSIGHT-004, R-INSIGHT-005).
///
/// The service composes only exported application contracts — the planner's
/// [PlannerSummaryContract] and the [CombinedTimeMetricsService] — never another
/// feature's infrastructure or domain (design.md §4). It carries the metric
/// policy version through unchanged and keeps every figure explainable: no
/// opaque composite score is ever produced (R-INSIGHT-005).
///
/// The close-derived metrics (task completion, habit consistency, missed and
/// carried counts) are the reproducible, policy-versioned portion. They are
/// cached in the `aggregate_cache` table keyed by `(window, policy-version,
/// source-watermark)`; a cache hit is only honored when the watermark still
/// matches, so a source change deterministically invalidates and recomputes it
/// (R-INSIGHT-004). The interval-unioned focus/study time is recomputed live on
/// every read and is never cached, so it can never be served stale.
final class PeriodInsightsService {
  const PeriodInsightsService({
    required this.plannerSummary,
    required this.combinedTime,
    required this.cache,
    required this.clock,
  });

  final PlannerSummaryContract plannerSummary;
  final CombinedTimeMetricsService combinedTime;
  final AggregateCacheStore cache;
  final Clock clock;

  /// The cache metric discriminator stored in `aggregate_cache.metric`.
  static const String _metric = 'period_insight';

  /// The habit occurrence status wire values captured in a factual close.
  static const String _statusCompleted = 'completed';
  static const String _statusMissed = 'missed';
  static const String _statusSkipped = 'skipped';
  static const String _statusPaused = 'paused';

  /// The weekly/monthly Insight for [period] scoped to [lifeAreaId].
  ///
  /// Days without a factual close do not contribute; a window with no closed
  /// days yields no-data task/habit metrics ("no data", not 0%, R-INSIGHT-002)
  /// while still reporting any interval-unioned focus/study time in the window.
  Future<PeriodInsight> insight(
    ProfileId profileId,
    InsightPeriod period, {
    required LifeAreaId lifeAreaId,
  }) async {
    // The focus/study union is always recomputed live from source spans so it
    // can never be served stale.
    final CombinedTimeMetrics time = await combinedTime.combinedTime(
      profileId,
      rangeStartUtc: period.rangeStartUtc,
      rangeEndUtc: period.rangeEndUtc,
      lifeAreaId: lifeAreaId,
    );

    final List<PlannerDailyCloseSnapshot> closes = await plannerSummary
        .dailyCloses(
          profileId,
          lifeAreaId: lifeAreaId,
          dayKeys: period.dayKeys,
        );

    if (closes.isEmpty) {
      // No factual close in the window: task/habit metrics are no-data, but any
      // focus/study time is still reported.
      return _build(
        period,
        lifeAreaId,
        const CachedPeriodMetrics(
          taskCompletion: MetricRatio.empty(),
          missedCount: 0,
          carriedCount: 0,
          habitConsistency: MetricRatio.empty(),
          metricPolicyNumber: MetricPolicyV1.number,
          sourceWatermarkCommitSeq: 0,
          closedDayCount: 0,
        ),
        time,
      );
    }

    final int watermark = closes
        .map((PlannerDailyCloseSnapshot c) => c.sourceWatermarkCommitSeq)
        .reduce(math.max);
    final int policyNumber = closes
        .map((PlannerDailyCloseSnapshot c) => c.metricPolicyNumber)
        .reduce(math.max);
    final String rangeHash = '${period.kind.wire}:${period.periodKey}';
    final String filterHash = lifeAreaId.value;
    final String cacheKey =
        '$_metric|$rangeHash|$filterHash|v$policyNumber|w$watermark';

    final CachedAggregate? hit = await cache.read(
      profileId.value,
      cacheKey: cacheKey,
    );
    if (hit != null && hit.sourceCommitSeq == watermark) {
      // Deterministic reproduction from the same watermark.
      return _build(
        period,
        lifeAreaId,
        PeriodInsightCodec.decode(hit.value),
        time,
      );
    }

    final CachedPeriodMetrics metrics = _aggregate(
      closes,
      watermark: watermark,
      policyNumber: policyNumber,
    );
    await cache.write(
      CachedAggregate(
        profileId: profileId.value,
        cacheKey: cacheKey,
        metric: _metric,
        rangeHash: rangeHash,
        filterHash: filterHash,
        policyVersion: policyNumber,
        sourceCommitSeq: watermark,
        value: PeriodInsightCodec.encode(metrics),
        updatedAtUtc: clock.utcNow().microsecondsSinceEpoch,
      ),
    );
    return _build(period, lifeAreaId, metrics, time);
  }

  /// The current Insight paired with its trend against the [previous]
  /// comparable-period Insight (R-INSIGHT-002). Pass a null [previous] when
  /// there is no comparable prior period; each trend is then absent.
  PeriodInsightComparison compare(
    PeriodInsight current, {
    PeriodInsight? previous,
  }) => PeriodInsightComparison(current: current, previous: previous);

  /// Aggregates the close-derived metrics over the contributing closes.
  CachedPeriodMetrics _aggregate(
    List<PlannerDailyCloseSnapshot> closes, {
    required int watermark,
    required int policyNumber,
  }) {
    int taskEligible = 0;
    int taskCompleted = 0;
    int missed = 0;
    int carried = 0;
    int habitEligible = 0;
    int habitCompleted = 0;

    for (final PlannerDailyCloseSnapshot close in closes) {
      taskEligible += close.tasks.eligibleCount;
      taskCompleted += close.tasks.completedCount;
      missed += close.tasks.missedCount;
      carried += close.tasks.carriedCount;

      for (final PlannerHabitCloseOutcome outcome in close.habits) {
        switch (outcome.statusWire) {
          case _statusPaused:
            // Paused occurrences are ineligible and excluded (R-HABIT-007).
            break;
          case _statusCompleted:
            habitEligible += 1;
            habitCompleted += 1;
          case _statusMissed:
          case _statusSkipped:
          default:
            // A skip stays in the denominator but never the numerator; any
            // other non-paused status is eligible and incomplete (R-HABIT-007).
            habitEligible += 1;
        }
      }
    }

    return CachedPeriodMetrics(
      taskCompletion: MetricRatio(
        numerator: taskCompleted,
        denominator: taskEligible,
      ),
      missedCount: missed,
      carriedCount: carried,
      habitConsistency: MetricRatio(
        numerator: habitCompleted,
        denominator: habitEligible,
      ),
      metricPolicyNumber: policyNumber,
      sourceWatermarkCommitSeq: watermark,
      closedDayCount: closes.length,
    );
  }

  PeriodInsight _build(
    InsightPeriod period,
    LifeAreaId lifeAreaId,
    CachedPeriodMetrics metrics,
    CombinedTimeMetrics time,
  ) => PeriodInsight(
    period: period,
    lifeAreaId: lifeAreaId.value,
    taskCompletion: metrics.taskCompletion,
    missedCount: metrics.missedCount,
    carriedCount: metrics.carriedCount,
    habitConsistency: metrics.habitConsistency,
    combinedFocusStudySeconds: time.combinedSeconds,
    focusStudyOverlapSeconds: time.overlapSeconds,
    metricPolicyNumber: metrics.metricPolicyNumber,
    sourceWatermarkCommitSeq: metrics.sourceWatermarkCommitSeq,
    closedDayCount: metrics.closedDayCount,
    memberDayCount: period.dayKeys.length,
  );
}
