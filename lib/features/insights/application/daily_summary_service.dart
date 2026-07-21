import 'package:forge/core/domain/id.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/insights/domain/daily_summary.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';

/// Composes the metric-policy-v1 Daily Summary for one planning day
/// (R-HOME-004, R-PLAN-003, R-HABIT-007).
///
/// This is the Wave 7 insights aggregation foundation. It reads the immutable
/// factual close through the planner's exported [PlannerSummaryContract] and the
/// interval-unioned focus + study time through [CombinedTimeMetricsService],
/// then stamps the result with the displayed metric policy version and the
/// source watermark that makes it reproducible (R-INSIGHT-004). It composes
/// only exported application contracts, never another feature's infrastructure
/// or domain (design.md §4).
///
/// The composed summary exhibits the four semantics the summary must guarantee:
///
/// * **set-union**: task completion reads the deduplicated eligible set sealed
///   at close, so a task that is both planned and due counts once;
/// * **as-of-close**: every task/habit value comes from the sealed close, so a
///   later correction or policy recomputation leaves the summary unchanged;
/// * **interval-union**: focus and study time are unioned so overlap is never
///   double-counted;
/// * **policy-version + watermark**: the summary carries the displayed policy
///   label and the commit sequence it was reproduced from.
final class DailySummaryService {
  const DailySummaryService({
    required this.plannerSummary,
    required this.combinedTime,
  });

  final PlannerSummaryContract plannerSummary;
  final CombinedTimeMetricsService combinedTime;

  /// The status wire values a habit occurrence can carry in a factual close.
  static const String _statusCompleted = 'completed';
  static const String _statusMissed = 'missed';
  static const String _statusSkipped = 'skipped';
  static const String _statusPaused = 'paused';

  /// The Daily Summary for `[lifeAreaId, dayKey]`, or null before that day's
  /// planning period has been closed (there is no factual snapshot to summarize
  /// yet). The focus/study time is unioned over `[dayStartUtc, dayEndUtc)`.
  Future<DailySummary?> summarize(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
    required int dayStartUtc,
    required int dayEndUtc,
  }) async {
    final PlannerDailyCloseSnapshot? snapshot = await plannerSummary.dailyClose(
      profileId,
      lifeAreaId: lifeAreaId,
      dayKey: dayKey,
    );
    if (snapshot == null) {
      return null;
    }

    final CombinedTimeMetrics time = await combinedTime.combinedTime(
      profileId,
      rangeStartUtc: dayStartUtc,
      rangeEndUtc: dayEndUtc,
      lifeAreaId: lifeAreaId,
    );

    return DailySummary(
      lifeAreaId: lifeAreaId.value,
      dayKey: dayKey,
      taskCompletion: MetricPolicyV1.taskCompletion(
        eligible: snapshot.tasks.eligibleCount,
        completed: snapshot.tasks.completedCount,
      ),
      habits: _tallyHabits(snapshot.habits),
      combinedFocusStudySeconds: time.combinedSeconds,
      focusStudyOverlapSeconds: time.overlapSeconds,
      metricPolicyNumber: snapshot.metricPolicyNumber,
      sourceWatermarkCommitSeq: snapshot.sourceWatermarkCommitSeq,
      closedAtUtc: snapshot.closedAtUtc,
      boundaryUtc: snapshot.boundaryUtc,
      eligibleRootHash: snapshot.tasks.eligibleRootHash,
      completedRootHash: snapshot.tasks.completedRootHash,
      adjustmentCount: snapshot.adjustmentCount,
      reflectionMd: snapshot.reflectionMd,
    );
  }

  /// Tallies the as-of-close habit occurrence statuses under metric policy v1.
  /// A paused occurrence is ineligible; any other status counts toward the
  /// denominator, and only `completed` counts toward the numerator (R-HABIT-007).
  DailyHabitOutcomes _tallyHabits(List<PlannerHabitCloseOutcome> outcomes) {
    int completed = 0;
    int missed = 0;
    int skipped = 0;
    int paused = 0;
    int open = 0;
    for (final PlannerHabitCloseOutcome outcome in outcomes) {
      switch (outcome.statusWire) {
        case _statusCompleted:
          completed += 1;
        case _statusMissed:
          missed += 1;
        case _statusSkipped:
          skipped += 1;
        case _statusPaused:
          paused += 1;
        default:
          // Any other sealed status (e.g. still `open` at close) is eligible
          // but not completed, so it sits in the denominator only.
          open += 1;
      }
    }
    return DailyHabitOutcomes(
      completed: completed,
      missed: missed,
      skipped: skipped,
      paused: paused,
      open: open,
    );
  }
}
