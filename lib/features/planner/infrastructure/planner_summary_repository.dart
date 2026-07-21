import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';
import 'package:forge/features/planner/domain/planner_repository.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// Reads a planning day's immutable factual close and projects it onto the
/// planner-exported [PlannerSummaryContract] (R-HOME-004, R-PLAN-003).
///
/// It composes the read-side [PlannerRepository] rather than touching Drift
/// directly, so the planner keeps one read path over the active generation
/// (design.md §5). The projection is pure surfacing: it never recomputes the
/// sealed counts, so the snapshot always reflects the factual close and not
/// later mutation.
final class PlannerSummaryRepository implements PlannerSummaryContract {
  const PlannerSummaryRepository(this._reads);

  final PlannerRepository _reads;

  /// The entity type stored for a habit occurrence close item.
  static const String _habitEntityType = 'habit_occurrence';

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async {
    final List<PlannerDailyCloseSnapshot> snapshots =
        <PlannerDailyCloseSnapshot>[];
    for (final String dayKey in dayKeys) {
      final PlannerDailyCloseSnapshot? snapshot = await dailyClose(
        profileId,
        lifeAreaId: lifeAreaId,
        dayKey: dayKey,
      );
      if (snapshot != null) {
        snapshots.add(snapshot);
      }
    }
    return snapshots;
  }

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async {
    final PlanningPeriod? period = await _reads.findByKey(
      profileId,
      lifeAreaId: lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: dayKey,
    );
    if (period == null) {
      return null;
    }
    final PlanningCloseEvent? close = await _reads.closeOf(
      profileId,
      period.id,
    );
    if (close == null) {
      // The day exists but has not been closed yet: no factual snapshot.
      return null;
    }

    final List<PlanningCloseItem> items = await _reads.closeItemsOf(
      profileId,
      close.id,
    );
    final List<PlanningCloseAdjustment> adjustments = await _reads
        .adjustmentsOf(profileId, close.id);

    final List<PlannerHabitCloseOutcome> habits = <PlannerHabitCloseOutcome>[
      for (final PlanningCloseItem item in items)
        if (item.entityType == _habitEntityType)
          PlannerHabitCloseOutcome(
            occurrenceId: item.entityId,
            statusWire: item.status,
          ),
    ];

    return PlannerDailyCloseSnapshot(
      periodId: period.id.value,
      closedAtUtc: close.closedAtUtc,
      boundaryUtc: close.boundaryUtc,
      metricPolicyNumber: close.metricPolicyVersion,
      sourceWatermarkCommitSeq: close.sourceCommitSeq,
      tasks: PlannerTaskCloseTally(
        eligibleCount: close.eligibleCount,
        completedCount: close.completedCount,
        missedCount: close.missedCount,
        carriedCount: close.carriedCount,
        eligibleRootHash: close.eligibleRootHash,
        completedRootHash: close.completedRootHash,
      ),
      habits: habits,
      adjustmentCount: adjustments.length,
      reflectionMd: period.eveningReflectionMd,
    );
  }
}
