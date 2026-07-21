import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/domain/planner_repository.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_entry_role.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_mapper.dart';

/// Read-side planner repository over the active Drift generation.
///
/// Query methods run outside a write transaction and return immutable domain
/// aggregates (design.md §5 "Queries").
final class PlannerReadRepository implements PlannerRepository {
  PlannerReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<PlanningPeriod?> findByKey(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required PlanningPeriodKind kind,
    required String periodKey,
  }) async {
    final PlanningPeriodRow? row =
        await (_db.select(_db.planningPeriods)..where(
              (PlanningPeriods p) =>
                  p.profileId.equals(profileId.value) &
                  p.lifeAreaId.equals(lifeAreaId.value) &
                  p.kind.equals(kind.wire) &
                  p.periodKey.equals(periodKey),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.periodFromRow(row);
  }

  @override
  Future<PlanningPeriod?> findById(
    ProfileId profileId,
    PlanningPeriodId periodId,
  ) async {
    final PlanningPeriodRow? row =
        await (_db.select(_db.planningPeriods)..where(
              (PlanningPeriods p) =>
                  p.profileId.equals(profileId.value) &
                  p.id.equals(periodId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.periodFromRow(row);
  }

  @override
  Future<List<PlanningEntry>> entriesOf(
    ProfileId profileId,
    PlanningPeriodId periodId,
  ) async {
    final List<PlanningEntryRow> rows =
        await (_db.select(_db.planningEntries)
              ..where(
                (PlanningEntries e) =>
                    e.profileId.equals(profileId.value) &
                    e.periodId.equals(periodId.value),
              )
              ..orderBy(<OrderClauseGenerator<PlanningEntries>>[
                (PlanningEntries e) => OrderingTerm.asc(e.rank),
                (PlanningEntries e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows.map(PlannerMapper.entryFromRow).toList(growable: false);
  }

  @override
  Future<List<CarryForwardCandidate>> previewCarryForward(
    ProfileId profileId,
    PlanningPeriodId sourcePeriodId, {
    required Set<String> completeEntityIds,
  }) async {
    final List<PlanningEntry> entries = await entriesOf(
      profileId,
      sourcePeriodId,
    );
    final List<CarryForwardCandidate> candidates = <CarryForwardCandidate>[];
    for (final PlanningEntry entry in entries) {
      // Carry-forward previews incomplete references so a completed reference is
      // never carried (R-PLAN-003). A carry entry can itself be carried on.
      final bool complete = completeEntityIds.contains(entry.entityId);
      if (!complete &&
          (entry.role == PlanningEntryRole.planned ||
              entry.role == PlanningEntryRole.carry)) {
        candidates.add(CarryForwardCandidate(entry: entry, isComplete: false));
      }
    }
    return candidates;
  }

  @override
  Future<PlanningCloseEvent?> closeOf(
    ProfileId profileId,
    PlanningPeriodId periodId,
  ) async {
    final PlanningCloseEventRow? row =
        await (_db.select(_db.planningCloseEvents)..where(
              (PlanningCloseEvents c) =>
                  c.profileId.equals(profileId.value) &
                  c.periodId.equals(periodId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.closeFromRow(row);
  }

  @override
  Future<List<PlanningCloseItem>> closeItemsOf(
    ProfileId profileId,
    String closeEventId,
  ) async {
    final List<PlanningCloseItemRow> rows =
        await (_db.select(_db.planningCloseItems)
              ..where(
                (PlanningCloseItems i) =>
                    i.profileId.equals(profileId.value) &
                    i.closeEventId.equals(closeEventId),
              )
              ..orderBy(<OrderClauseGenerator<PlanningCloseItems>>[
                (PlanningCloseItems i) => OrderingTerm.asc(i.entityType),
                (PlanningCloseItems i) => OrderingTerm.asc(i.entityId),
              ]))
            .get();
    return rows.map(PlannerMapper.closeItemFromRow).toList(growable: false);
  }

  @override
  Future<List<PlanningCloseAdjustment>> adjustmentsOf(
    ProfileId profileId,
    String closeEventId,
  ) async {
    final List<PlanningCloseAdjustmentRow> rows =
        await (_db.select(_db.planningCloseAdjustments)
              ..where(
                (PlanningCloseAdjustments a) =>
                    a.profileId.equals(profileId.value) &
                    a.closeEventId.equals(closeEventId),
              )
              ..orderBy(<OrderClauseGenerator<PlanningCloseAdjustments>>[
                (PlanningCloseAdjustments a) =>
                    OrderingTerm.asc(a.occurredAtUtc),
                (PlanningCloseAdjustments a) => OrderingTerm.asc(a.id),
              ]))
            .get();
    return rows.map(PlannerMapper.adjustmentFromRow).toList(growable: false);
  }
}
