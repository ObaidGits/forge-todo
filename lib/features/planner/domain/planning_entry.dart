import 'package:forge/features/planner/domain/planning_entry_role.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';

/// An immutable reference from a planning record to a task/goal/habit/note
/// (R-PLAN-002, R-PLAN-003).
///
/// A planning entry references an entity by `(referenceType, entityId)` rather
/// than cloning it. It is inherited-area owned: it derives its profile and Life
/// Area from its parent `planning_periods` row through the composite
/// `(profile_id, period_id)` foreign key (data-model §1).
///
/// * A [PlanningEntryRole.planned] entry has no [carriedFromEntryId].
/// * A [PlanningEntryRole.carry] entry records the carry-forward relation to
///   the source entry it was carried from, so the carried-forward subset is
///   auditable and never double-counted.
final class PlanningEntry {
  PlanningEntry({
    required this.id,
    required this.profileId,
    required this.periodId,
    required this.referenceType,
    required this.entityId,
    required this.role,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.carriedFromEntryId,
  }) {
    if (entityId.trim().isEmpty) {
      throw const FormatException(
        'Planning entry entity id must not be empty.',
      );
    }
    if (role == PlanningEntryRole.planned && carriedFromEntryId != null) {
      throw const FormatException(
        'A planned entry must not carry a carried_from relation.',
      );
    }
    if (role == PlanningEntryRole.carry && carriedFromEntryId == null) {
      throw const FormatException(
        'A carry entry must record its carried_from relation.',
      );
    }
  }

  final String id;
  final String profileId;
  final String periodId;
  final PlanningReferenceType referenceType;
  final String entityId;
  final PlanningEntryRole role;

  /// The source entry a [PlanningEntryRole.carry] entry was carried from; null
  /// for a [PlanningEntryRole.planned] entry.
  final String? carriedFromEntryId;

  /// Stable manual ordering rank within the period.
  final String rank;

  final int createdAtUtc;
  final int updatedAtUtc;
}
