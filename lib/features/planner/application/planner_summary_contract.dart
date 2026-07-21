import 'package:forge/core/domain/id.dart';

/// The planner-exported, as-of-close snapshot consumed by the insights Daily
/// Summary (R-HOME-004, R-PLAN-003).
///
/// The planner feature exclusively owns `planning_periods`,
/// `planning_close_events`, `planning_close_items`, and
/// `planning_close_adjustments`; other features read them only through this
/// application contract (data-model §1, design.md §4). Every field is a
/// primitive so a consumer never needs a planner infrastructure or domain
/// import: the insights feature depends on this contract alone.
///
/// The snapshot is the *factual close* — a task or habit that was corrected
/// after close is reflected here exactly as it was sealed, and later
/// corrections are surfaced only as [adjustmentCount]. The consumer therefore
/// gets stable, reproducible numbers keyed by [sourceWatermarkCommitSeq]
/// (R-INSIGHT-004).

/// The as-of-close task counts of a factual close (set-union of planned and due,
/// deduplicated, R-HOME-004).
final class PlannerTaskCloseTally {
  const PlannerTaskCloseTally({
    required this.eligibleCount,
    required this.completedCount,
    required this.missedCount,
    required this.carriedCount,
    required this.eligibleRootHash,
    required this.completedRootHash,
  });

  final int eligibleCount;
  final int completedCount;

  /// Eligible planned tasks incomplete at the planning-day boundary.
  final int missedCount;

  /// The labeled carried-forward subset; a subset of missed, never
  /// double-counted.
  final int carriedCount;

  /// Deterministic root hash over the eligible task set for reproduction.
  final String eligibleRootHash;

  /// Deterministic root hash over the completed task set.
  final String completedRootHash;
}

/// The as-of-close status of one habit occurrence captured in a factual close.
final class PlannerHabitCloseOutcome {
  const PlannerHabitCloseOutcome({
    required this.occurrenceId,
    required this.statusWire,
  });

  final String occurrenceId;

  /// The sealed occurrence status wire value: `completed`, `missed`, `skipped`,
  /// `paused`, or `open`.
  final String statusWire;
}

/// The full as-of-close snapshot of one planning day (R-HOME-004, R-PLAN-003).
final class PlannerDailyCloseSnapshot {
  const PlannerDailyCloseSnapshot({
    required this.periodId,
    required this.closedAtUtc,
    required this.boundaryUtc,
    required this.metricPolicyNumber,
    required this.sourceWatermarkCommitSeq,
    required this.tasks,
    required this.habits,
    required this.adjustmentCount,
    this.reflectionMd,
  });

  final String periodId;

  /// The instant the factual close was taken.
  final int closedAtUtc;

  /// The planning-day boundary at which "missed" was evaluated.
  final int boundaryUtc;

  /// The numeric metric policy in effect at close.
  final int metricPolicyNumber;

  /// The commit sequence the close observed (the reproduction watermark).
  final int sourceWatermarkCommitSeq;

  final PlannerTaskCloseTally tasks;
  final List<PlannerHabitCloseOutcome> habits;

  /// The number of linked adjustments appended after close (source corrections
  /// and policy recomputations). They never change the sealed values above.
  final int adjustmentCount;

  /// The day's private evening reflection Markdown, or null when none exists.
  final String? reflectionMd;
}

/// Read contract that surfaces a day's immutable factual close for the Daily
/// Summary. Returns null before the day's period is closed (R-HOME-004).
abstract interface class PlannerSummaryContract {
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  });

  /// The factual daily closes that exist among [dayKeys], omitting any day
  /// whose planning period has not been closed. Used by weekly/monthly Insights
  /// to aggregate over the same immutable as-of-close snapshots so the range
  /// metric is reproducible from each day's watermark (R-INSIGHT-001,
  /// R-INSIGHT-004). The result preserves the input order of the days that
  /// exist and are closed.
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  });
}
