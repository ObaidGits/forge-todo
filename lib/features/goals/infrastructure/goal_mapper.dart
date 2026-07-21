import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/goal_status.dart';

/// Explicit mapping between the `goals` Drift row and the immutable [Goal]
/// domain aggregate (design.md "Data Models").
abstract final class GoalMapper {
  static Goal fromRow(GoalRow row) => Goal(
    id: GoalId(row.id),
    profileId: ProfileId(row.profileId),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    title: row.title,
    outcomeMd: row.outcomeMd,
    status: GoalStatus.fromWire(row.status),
    targetDate: row.targetDate,
    progressMode: GoalProgressMode.fromWire(row.progressMode),
    manualProgress: row.manualProgress,
    noteId: row.noteId == null ? null : NoteId(row.noteId!),
    archivedAtUtc: row.archivedAtUtc,
    rank: GoalRank(row.rank),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static GoalsCompanion toInsert(Goal goal) => GoalsCompanion.insert(
    id: goal.id.value,
    profileId: goal.profileId.value,
    lifeAreaId: goal.lifeAreaId.value,
    title: goal.title,
    outcomeMd: Value<String>(goal.outcomeMd),
    status: goal.status.wire,
    targetDate: Value<String?>(goal.targetDate),
    progressMode: goal.progressMode.wire,
    manualProgress: Value<double?>(goal.manualProgress),
    noteId: Value<String?>(goal.noteId?.value),
    archivedAtUtc: Value<int?>(goal.archivedAtUtc),
    rank: goal.rank.value,
    revision: Value<int>(goal.revision),
    createdAtUtc: goal.createdAtUtc,
    updatedAtUtc: goal.updatedAtUtc,
    deletedAtUtc: Value<int?>(goal.deletedAtUtc),
  );

  /// A full-row update companion. Every mutable column is written (possibly to
  /// null) so switching progress mode clears the manual value, and unarchiving
  /// clears the archive instant.
  static GoalsCompanion toUpdate(Goal goal) => GoalsCompanion(
    lifeAreaId: Value<String>(goal.lifeAreaId.value),
    title: Value<String>(goal.title),
    outcomeMd: Value<String>(goal.outcomeMd),
    status: Value<String>(goal.status.wire),
    targetDate: Value<String?>(goal.targetDate),
    progressMode: Value<String>(goal.progressMode.wire),
    manualProgress: Value<double?>(goal.manualProgress),
    noteId: Value<String?>(goal.noteId?.value),
    archivedAtUtc: Value<int?>(goal.archivedAtUtc),
    rank: Value<String>(goal.rank.value),
    revision: Value<int>(goal.revision),
    updatedAtUtc: Value<int>(goal.updatedAtUtc),
    deletedAtUtc: Value<int?>(goal.deletedAtUtc),
  );
}
