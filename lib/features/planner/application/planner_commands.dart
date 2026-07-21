import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';

/// Input to save (create or update) an area-scoped planning record's sections
/// (R-PLAN-001, R-PLAN-004).
///
/// The record is addressed by its composite key `(lifeAreaId, kind, periodKey)`
/// within the active profile. Only the sections applicable to [kind] may be
/// set; the command rejects a section outside its kind. A `null` section leaves
/// that section unchanged when the record already exists; use
/// [SectionEdit.clear] to explicitly clear a section.
final class SavePlanningRecordInput {
  const SavePlanningRecordInput({
    required this.lifeAreaId,
    required this.kind,
    required this.periodKey,
    this.morningPlanMd = SectionEdit.unchanged,
    this.dailyPlanMd = SectionEdit.unchanged,
    this.eveningReflectionMd = SectionEdit.unchanged,
    this.eveningPromptsJson = SectionEdit.unchanged,
    this.planIntentionMd = SectionEdit.unchanged,
    this.reflectionMd = SectionEdit.unchanged,
    this.promptVersion,
  });

  final String lifeAreaId;
  final PlanningPeriodKind kind;
  final String periodKey;

  final SectionEdit morningPlanMd;
  final SectionEdit dailyPlanMd;
  final SectionEdit eveningReflectionMd;
  final SectionEdit eveningPromptsJson;
  final SectionEdit planIntentionMd;
  final SectionEdit reflectionMd;

  /// When set, updates the prompt configuration version.
  final int? promptVersion;
}

/// A tri-state section edit: leave unchanged, clear to null, or set a value.
final class SectionEdit {
  const SectionEdit._(this._kind, this.value);

  /// Leave the existing section content unchanged.
  static const SectionEdit unchanged = SectionEdit._(_EditKind.unchanged, null);

  /// Clear the section to null.
  static const SectionEdit clear = SectionEdit._(_EditKind.clear, null);

  /// Set the section to [value].
  factory SectionEdit.set(String value) => SectionEdit._(_EditKind.set, value);

  final _EditKind _kind;
  final String? value;

  bool get isUnchanged => _kind == _EditKind.unchanged;
  bool get isClear => _kind == _EditKind.clear;
  bool get isSet => _kind == _EditKind.set;
}

enum _EditKind { unchanged, clear, set }

/// Input to add a reference from a planning record to a task/goal/habit/note
/// (R-PLAN-002).
final class AddReferenceInput {
  const AddReferenceInput({
    required this.periodId,
    required this.referenceType,
    required this.entityId,
  });

  final String periodId;
  final PlanningReferenceType referenceType;
  final String entityId;
}

/// Input to carry forward selected incomplete references from a source period
/// into a target period (R-PLAN-003).
///
/// Carry-forward records the carry-forward relation and never alters task due
/// dates. Each selected reference becomes a `carry` entry in the target period
/// linked to its source entry.
final class CarryForwardInput {
  const CarryForwardInput({
    required this.sourcePeriodId,
    required this.targetPeriodId,
    required this.sourceEntryIds,
  });

  final String sourcePeriodId;
  final String targetPeriodId;

  /// The source `planning_entries` ids selected during preview.
  final List<String> sourceEntryIds;
}

/// One task fact supplied to the factual close (R-PLAN-003, R-HOME-004).
final class CloseTaskInput {
  const CloseTaskInput({
    required this.taskId,
    required this.isPlanned,
    required this.isDue,
    required this.completedAtOrBeforeBoundary,
    this.cancelledBeforeClose = false,
    this.taskDueDate,
    this.sourceEventId,
  });

  final String taskId;
  final bool isPlanned;
  final bool isDue;
  final bool completedAtOrBeforeBoundary;
  final bool cancelledBeforeClose;
  final String? taskDueDate;
  final String? sourceEventId;
}

/// One habit-occurrence fact captured in the factual close snapshot.
final class CloseHabitInput {
  const CloseHabitInput({
    required this.occurrenceId,
    required this.status,
    this.sourceEventId,
  });

  final String occurrenceId;

  /// The as-of-close habit occurrence status projection (e.g. `completed`,
  /// `missed`, `skipped`).
  final String status;
  final String? sourceEventId;
}

/// Input to take the single immutable factual close of a planning period
/// (R-PLAN-003).
final class ClosePeriodInput {
  const ClosePeriodInput({
    required this.periodId,
    required this.boundaryUtc,
    required this.metricPolicyVersion,
    this.tasks = const <CloseTaskInput>[],
    this.habits = const <CloseHabitInput>[],
    this.carriedTaskIds = const <String>{},
  });

  final String periodId;

  /// The planning-day boundary instant at which "missed" is evaluated.
  final int boundaryUtc;

  /// The metric policy active at close (recorded for audit only; the snapshot
  /// itself is policy-independent).
  final int metricPolicyVersion;

  final List<CloseTaskInput> tasks;
  final List<CloseHabitInput> habits;

  /// The labeled carried-forward subset; each id must be a missed planned task.
  final Set<String> carriedTaskIds;
}

/// Input to append a source-correction adjustment to an immutable factual close
/// (R-PLAN-003, R-HABIT-005).
final class SourceCorrectionInput {
  const SourceCorrectionInput({
    required this.periodId,
    required this.affectedEntityType,
    required this.affectedEntityId,
    required this.affectedMetric,
    required this.priorClassification,
    required this.currentClassification,
    required this.delta,
    this.sourceEventId,
    this.sourceCommitSeq,
    this.reason,
  });

  final String periodId;
  final String affectedEntityType;
  final String affectedEntityId;
  final String affectedMetric;
  final String priorClassification;
  final String currentClassification;
  final int delta;
  final String? sourceEventId;
  final int? sourceCommitSeq;
  final String? reason;
}

/// Input to append a policy-recomputation adjustment to an immutable factual
/// close (R-PLAN-003).
///
/// Recalculation under a newer metric policy creates a separate derived
/// recomputation/cache record and never creates or replaces a factual close.
final class PolicyRecomputationInput {
  const PolicyRecomputationInput({
    required this.periodId,
    required this.metricPolicyVersion,
    required this.derivedSummaryJson,
    this.affectedMetric,
    this.reason,
  });

  final String periodId;
  final int metricPolicyVersion;
  final String derivedSummaryJson;
  final String? affectedMetric;
  final String? reason;
}
