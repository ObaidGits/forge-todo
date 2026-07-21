import 'package:forge/features/planner/domain/planning_close_adjustment_kind.dart';

/// The immutable factual close snapshot of one planning period (R-PLAN-003,
/// R-HOME-004).
///
/// Each planning period has exactly one idempotent, immutable factual close
/// snapshot, independent of policy version. It records the raw, as-of-close
/// facts — the counts and set root hashes — so later metrics are always
/// reproducible. It is never rewritten: later source corrections and
/// policy recomputations are appended as linked [PlanningCloseAdjustment]
/// records.
final class PlanningCloseEvent {
  const PlanningCloseEvent({
    required this.id,
    required this.profileId,
    required this.periodId,
    required this.closedAtUtc,
    required this.boundaryUtc,
    required this.metricPolicyVersion,
    required this.sourceCommitSeq,
    required this.eligibleCount,
    required this.completedCount,
    required this.missedCount,
    required this.carriedCount,
    required this.eligibleRootHash,
    required this.completedRootHash,
    required this.createdAtUtc,
  });

  final String id;
  final String profileId;
  final String periodId;

  /// The instant the factual close was taken.
  final int closedAtUtc;

  /// The planning-day boundary instant at which "missed" is evaluated: an
  /// eligible planned task incomplete at this boundary is missed (R-PLAN-003).
  final int boundaryUtc;

  /// The metric policy in effect at close. The snapshot itself is factual and
  /// independent of this; recomputation under a newer policy appends a derived
  /// adjustment rather than a new close.
  final int metricPolicyVersion;

  /// The commit sequence the close observed, so the snapshot is reproducible
  /// from source events (R-INSIGHT-004).
  final int sourceCommitSeq;

  final int eligibleCount;
  final int completedCount;

  /// Eligible planned tasks incomplete at [boundaryUtc] (R-PLAN-003).
  final int missedCount;

  /// The labeled carried-forward subset; a subset of missed, not double-counted.
  final int carriedCount;

  /// Deterministic root hash over the eligible item set for audit/metric
  /// reproduction.
  final String eligibleRootHash;

  /// Deterministic root hash over the completed item set.
  final String completedRootHash;

  final int createdAtUtc;
}

/// One item captured in a factual close: a planned/due task or a habit
/// occurrence, with its as-of-close classification (R-PLAN-003, R-HOME-004).
final class PlanningCloseItem {
  const PlanningCloseItem({
    required this.profileId,
    required this.closeEventId,
    required this.entityType,
    required this.entityId,
    required this.status,
    this.isPlanned,
    this.isDue,
    this.taskDueDate,
    this.sourceEventId,
  });

  final String profileId;
  final String closeEventId;

  /// `task` or `habit_occurrence`.
  final String entityType;
  final String entityId;

  /// Whether the task was planned into the period (null for a habit occurrence).
  final bool? isPlanned;

  /// Whether the task's due date/instant fell in the period (null for a habit).
  final bool? isDue;

  /// The task's floating due date at close, when present.
  final String? taskDueDate;

  /// The as-of-close status classification, e.g. `completed`, `missed`,
  /// `carried`, `open`.
  final String status;

  /// The source event ID (completion/check-in) observed at factual close.
  final String? sourceEventId;
}

/// A linked, append-only adjustment to an immutable factual close
/// (R-PLAN-003, R-HABIT-005).
///
/// A [PlanningCloseAdjustmentKind.sourceCorrection] records a later correction
/// to a source event with its prior/current classification delta. A
/// [PlanningCloseAdjustmentKind.policyRecomputation] records a recalculation
/// under a newer metric policy as a derived record. Neither ever rewrites the
/// factual close.
final class PlanningCloseAdjustment {
  const PlanningCloseAdjustment({
    required this.id,
    required this.profileId,
    required this.closeEventId,
    required this.kind,
    required this.metricPolicyVersion,
    required this.occurredAtUtc,
    required this.createdAtUtc,
    this.sourceCommandId,
    this.sourceEventId,
    this.sourceCommitSeq,
    this.reason,
    this.affectedEntityType,
    this.affectedEntityId,
    this.affectedMetric,
    this.priorClassification,
    this.currentClassification,
    this.delta,
    this.derivedSummaryJson,
    this.derivedRootHash,
    this.supersedesId,
  });

  final String id;
  final String profileId;
  final String closeEventId;
  final PlanningCloseAdjustmentKind kind;
  final int metricPolicyVersion;
  final int occurredAtUtc;
  final int createdAtUtc;

  final String? sourceCommandId;
  final String? sourceEventId;
  final int? sourceCommitSeq;
  final String? reason;
  final String? affectedEntityType;
  final String? affectedEntityId;
  final String? affectedMetric;
  final String? priorClassification;
  final String? currentClassification;
  final int? delta;
  final String? derivedSummaryJson;
  final String? derivedRootHash;
  final String? supersedesId;
}
