import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/milestone.dart';

/// Named goal list views (R-GOAL-002, R-GOAL-007).
enum GoalViewKind {
  /// Live, non-archived goals ordered by rank.
  active,

  /// Archived goals (history preserved) ordered by most recently archived.
  archived,

  /// Soft-deleted goals.
  trash,
}

/// A composable structured goal filter.
///
/// Every field is optional and combined with logical AND. Free [titleContains]
/// text is a simple substring fallback; FTS-backed search is served by the
/// unified search read model (R-SEARCH-001).
final class GoalQuery {
  const GoalQuery({
    this.statuses,
    this.lifeAreaId,
    this.archived,
    this.tagId,
    this.targetFromDate,
    this.targetToDate,
    this.titleContains,
    this.includeDeleted = false,
    this.onlyDeleted = false,
    this.limit,
  });

  final Set<GoalStatus>? statuses;
  final LifeAreaId? lifeAreaId;

  /// When set, restricts to archived (`true`) or non-archived (`false`) goals.
  final bool? archived;

  final String? tagId;

  /// Inclusive floating-date range over `target_date`.
  final String? targetFromDate;
  final String? targetToDate;

  final String? titleContains;

  final bool includeDeleted;
  final bool onlyDeleted;
  final int? limit;
}

/// Read access to goals and their milestones. Query methods run outside a write
/// transaction and return immutable domain aggregates.
abstract interface class GoalRepository {
  Future<Goal?> findById(ProfileId profileId, GoalId goalId);

  Future<List<Goal>> query(ProfileId profileId, GoalQuery filter);

  Future<List<Goal>> view(
    ProfileId profileId,
    GoalViewKind kind, {
    LifeAreaId? lifeAreaId,
  });

  /// The ids of the tags linked to [goalId] through `entity_tags`.
  Future<List<String>> tagIdsFor(ProfileId profileId, GoalId goalId);

  /// The non-deleted milestones of [goalId], ordered by rank.
  Future<List<Milestone>> milestonesOf(ProfileId profileId, GoalId goalId);

  Future<Milestone?> findMilestone(
    ProfileId profileId,
    MilestoneId milestoneId,
  );
}
