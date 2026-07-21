import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_close_adjustment_kind.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_entry_role.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';

/// Explicit mapping between the planner Drift rows and immutable domain
/// aggregates (design.md "Data Models").
abstract final class PlannerMapper {
  static PlanningPeriod periodFromRow(PlanningPeriodRow row) => PlanningPeriod(
    id: PlanningPeriodId(row.id),
    profileId: ProfileId(row.profileId),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    kind: PlanningPeriodKind.fromWire(row.kind),
    periodKey: row.periodKey,
    morningPlanMd: row.morningPlanMd,
    dailyPlanMd: row.dailyPlanMd,
    eveningReflectionMd: row.eveningReflectionMd,
    eveningPromptsJson: row.eveningPromptsJson,
    planIntentionMd: row.planIntentionMd,
    reflectionMd: row.reflectionMd,
    promptVersion: row.promptVersion,
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static PlanningPeriodsCompanion periodToInsert(PlanningPeriod period) =>
      PlanningPeriodsCompanion.insert(
        id: period.id.value,
        profileId: period.profileId.value,
        lifeAreaId: period.lifeAreaId.value,
        kind: period.kind.wire,
        periodKey: period.periodKey,
        morningPlanMd: Value<String?>(period.morningPlanMd),
        dailyPlanMd: Value<String?>(period.dailyPlanMd),
        eveningReflectionMd: Value<String?>(period.eveningReflectionMd),
        eveningPromptsJson: Value<String?>(period.eveningPromptsJson),
        planIntentionMd: Value<String?>(period.planIntentionMd),
        reflectionMd: Value<String?>(period.reflectionMd),
        promptVersion: Value<int>(period.promptVersion),
        revision: Value<int>(period.revision),
        createdAtUtc: period.createdAtUtc,
        updatedAtUtc: period.updatedAtUtc,
        deletedAtUtc: Value<int?>(period.deletedAtUtc),
      );

  static PlanningPeriodsCompanion periodToUpdate(PlanningPeriod period) =>
      PlanningPeriodsCompanion(
        morningPlanMd: Value<String?>(period.morningPlanMd),
        dailyPlanMd: Value<String?>(period.dailyPlanMd),
        eveningReflectionMd: Value<String?>(period.eveningReflectionMd),
        eveningPromptsJson: Value<String?>(period.eveningPromptsJson),
        planIntentionMd: Value<String?>(period.planIntentionMd),
        reflectionMd: Value<String?>(period.reflectionMd),
        promptVersion: Value<int>(period.promptVersion),
        revision: Value<int>(period.revision),
        updatedAtUtc: Value<int>(period.updatedAtUtc),
        deletedAtUtc: Value<int?>(period.deletedAtUtc),
      );

  static PlanningEntry entryFromRow(PlanningEntryRow row) => PlanningEntry(
    id: row.id,
    profileId: row.profileId,
    periodId: row.periodId,
    referenceType: PlanningReferenceType.fromWire(row.entityType),
    entityId: row.entityId,
    role: PlanningEntryRole.fromWire(row.role),
    carriedFromEntryId: row.carriedFromEntryId,
    rank: row.rank,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
  );

  static PlanningEntriesCompanion entryToInsert(
    PlanningEntry entry, {
    String? addedEventId,
  }) => PlanningEntriesCompanion.insert(
    id: entry.id,
    profileId: entry.profileId,
    periodId: entry.periodId,
    entityType: entry.referenceType.wire,
    entityId: entry.entityId,
    role: entry.role.wire,
    carriedFromEntryId: Value<String?>(entry.carriedFromEntryId),
    rank: entry.rank,
    addedEventId: Value<String?>(addedEventId),
    createdAtUtc: entry.createdAtUtc,
    updatedAtUtc: entry.updatedAtUtc,
  );

  static PlanningCloseEvent closeFromRow(PlanningCloseEventRow row) =>
      PlanningCloseEvent(
        id: row.id,
        profileId: row.profileId,
        periodId: row.periodId,
        closedAtUtc: row.closedAtUtc,
        boundaryUtc: row.boundaryUtc,
        metricPolicyVersion: row.metricPolicyVersion,
        sourceCommitSeq: row.sourceCommitSeq,
        eligibleCount: row.eligibleCount,
        completedCount: row.completedCount,
        missedCount: row.missedCount,
        carriedCount: row.carriedCount,
        eligibleRootHash: row.eligibleRootHash,
        completedRootHash: row.completedRootHash,
        createdAtUtc: row.createdAtUtc,
      );

  static PlanningCloseItem closeItemFromRow(PlanningCloseItemRow row) =>
      PlanningCloseItem(
        profileId: row.profileId,
        closeEventId: row.closeEventId,
        entityType: row.entityType,
        entityId: row.entityId,
        isPlanned: row.isPlanned,
        isDue: row.isDue,
        taskDueDate: row.taskDueDate,
        status: row.status,
        sourceEventId: row.sourceEventId,
      );

  static PlanningCloseAdjustment adjustmentFromRow(
    PlanningCloseAdjustmentRow row,
  ) => PlanningCloseAdjustment(
    id: row.id,
    profileId: row.profileId,
    closeEventId: row.closeEventId,
    kind: PlanningCloseAdjustmentKind.fromWire(row.kind),
    metricPolicyVersion: row.metricPolicyVersion,
    occurredAtUtc: row.occurredAtUtc,
    createdAtUtc: row.createdAtUtc,
    sourceCommandId: row.sourceCommandId,
    sourceEventId: row.sourceEventId,
    sourceCommitSeq: row.sourceCommitSeq,
    reason: row.reason,
    affectedEntityType: row.affectedEntityType,
    affectedEntityId: row.affectedEntityId,
    affectedMetric: row.affectedMetric,
    priorClassification: row.priorClassification,
    currentClassification: row.currentClassification,
    delta: row.delta,
    derivedSummaryJson: row.derivedSummaryJson,
    derivedRootHash: row.derivedRootHash,
    supersedesId: row.supersedesId,
  );
}
