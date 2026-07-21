import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// A carry-forward preview candidate: an incomplete reference in a source
/// period that may be carried forward (R-PLAN-003).
final class CarryForwardCandidate {
  const CarryForwardCandidate({required this.entry, required this.isComplete});

  final PlanningEntry entry;

  /// Whether the referenced entity was complete at preview time. Only
  /// incomplete references are eligible to carry forward.
  final bool isComplete;
}

/// Read access to planner records. Query methods run outside a write
/// transaction and return immutable domain aggregates.
abstract interface class PlannerRepository {
  /// The single area-scoped record for the composite key, or null when none
  /// exists (R-PLAN-001).
  Future<PlanningPeriod?> findByKey(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required PlanningPeriodKind kind,
    required String periodKey,
  });

  Future<PlanningPeriod?> findById(
    ProfileId profileId,
    PlanningPeriodId periodId,
  );

  /// The entries of a period, ordered by rank.
  Future<List<PlanningEntry>> entriesOf(
    ProfileId profileId,
    PlanningPeriodId periodId,
  );

  /// The incomplete references of a source period eligible to carry forward.
  /// [completeEntityIds] are the ids of references already complete at preview
  /// time; every other planned/carry reference is returned as a candidate.
  Future<List<CarryForwardCandidate>> previewCarryForward(
    ProfileId profileId,
    PlanningPeriodId sourcePeriodId, {
    required Set<String> completeEntityIds,
  });

  /// The single immutable factual close of a period, or null before it closed.
  Future<PlanningCloseEvent?> closeOf(
    ProfileId profileId,
    PlanningPeriodId periodId,
  );

  /// The captured items of a factual close.
  Future<List<PlanningCloseItem>> closeItemsOf(
    ProfileId profileId,
    String closeEventId,
  );

  /// The append-only adjustments linked to a factual close, oldest first.
  Future<List<PlanningCloseAdjustment>> adjustmentsOf(
    ProfileId profileId,
    String closeEventId,
  );
}
