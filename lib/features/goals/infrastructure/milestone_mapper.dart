import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/milestone.dart';

/// Explicit mapping between the `milestones` Drift row and the immutable
/// [Milestone] domain aggregate (design.md "Data Models").
abstract final class MilestoneMapper {
  static Milestone fromRow(MilestoneRow row) => Milestone(
    id: MilestoneId(row.id),
    profileId: ProfileId(row.profileId),
    goalId: GoalId(row.goalId),
    title: row.title,
    targetDate: row.targetDate,
    completedAtUtc: row.completedAtUtc,
    rank: GoalRank(row.rank),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static MilestonesCompanion toInsert(Milestone milestone) =>
      MilestonesCompanion.insert(
        id: milestone.id.value,
        profileId: milestone.profileId.value,
        goalId: milestone.goalId.value,
        title: milestone.title,
        targetDate: Value<String?>(milestone.targetDate),
        completedAtUtc: Value<int?>(milestone.completedAtUtc),
        rank: milestone.rank.value,
        revision: Value<int>(milestone.revision),
        createdAtUtc: milestone.createdAtUtc,
        updatedAtUtc: milestone.updatedAtUtc,
        deletedAtUtc: Value<int?>(milestone.deletedAtUtc),
      );

  static MilestonesCompanion toUpdate(Milestone milestone) =>
      MilestonesCompanion(
        title: Value<String>(milestone.title),
        targetDate: Value<String?>(milestone.targetDate),
        completedAtUtc: Value<int?>(milestone.completedAtUtc),
        rank: Value<String>(milestone.rank.value),
        revision: Value<int>(milestone.revision),
        updatedAtUtc: Value<int>(milestone.updatedAtUtc),
        deletedAtUtc: Value<int?>(milestone.deletedAtUtc),
      );
}
