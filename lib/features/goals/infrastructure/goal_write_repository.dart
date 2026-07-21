import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/goals/infrastructure/goal_mapper.dart';
import 'package:forge/features/goals/infrastructure/milestone_mapper.dart';

/// Transaction-scoped write access to `goals`, `milestones`, and the goal's
/// `entity_tags`.
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes.
final class GoalWriteRepository {
  GoalWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- goals --------------------------------------------------------------

  Future<Goal?> find(String profileId, String goalId) async {
    scope.ensureActive();
    final GoalRow? row =
        await (db.select(db.goals)..where(
              (Goals t) => t.profileId.equals(profileId) & t.id.equals(goalId),
            ))
            .getSingleOrNull();
    return row == null ? null : GoalMapper.fromRow(row);
  }

  Future<void> insert(Goal goal) async {
    scope.ensureActive();
    await db.into(db.goals).insert(GoalMapper.toInsert(goal));
  }

  Future<void> update(Goal goal) async {
    scope.ensureActive();
    await (db.update(db.goals)..where(
          (Goals t) =>
              t.profileId.equals(goal.profileId.value) &
              t.id.equals(goal.id.value),
        ))
        .write(GoalMapper.toUpdate(goal));
  }

  /// The highest existing goal rank for [profileId] among live goals, used to
  /// append a new goal at the end.
  Future<GoalRank?> lastGoalRank(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM goals WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  /// The ids of every non-deleted goal for [profileId], for the search rebuild
  /// path.
  Future<List<String>> activeIds(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM goals WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY id ASC',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  // ---- milestones ---------------------------------------------------------

  Future<Milestone?> findMilestone(String profileId, String milestoneId) async {
    scope.ensureActive();
    final MilestoneRow? row =
        await (db.select(db.milestones)..where(
              (Milestones t) =>
                  t.profileId.equals(profileId) & t.id.equals(milestoneId),
            ))
            .getSingleOrNull();
    return row == null ? null : MilestoneMapper.fromRow(row);
  }

  Future<void> insertMilestone(Milestone milestone) async {
    scope.ensureActive();
    await db.into(db.milestones).insert(MilestoneMapper.toInsert(milestone));
  }

  Future<void> updateMilestone(Milestone milestone) async {
    scope.ensureActive();
    await (db.update(db.milestones)..where(
          (Milestones t) =>
              t.profileId.equals(milestone.profileId.value) &
              t.id.equals(milestone.id.value),
        ))
        .write(MilestoneMapper.toUpdate(milestone));
  }

  /// The highest existing milestone rank under [goalId] among live milestones.
  Future<GoalRank?> lastMilestoneRank(String profileId, String goalId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM milestones WHERE profile_id = ? AND goal_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(goalId),
          ],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  // ---- tags ---------------------------------------------------------------

  /// Attaches [tagId] to a goal through `entity_tags`. Idempotent per the
  /// composite primary key.
  Future<void> attachTag({
    required String profileId,
    required String goalId,
    required String tagId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT OR IGNORE INTO entity_tags '
      '(profile_id, entity_type, entity_id, tag_id, created_at_utc) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[profileId, 'goal', goalId, tagId, nowUtc],
    );
  }

  /// True when a live (non-deleted) note [noteId] exists under [profileId],
  /// used to reject a canonical-note reference that does not resolve locally
  /// (R-GEN-002). Returns false when the notes table is absent in a given
  /// generation, so goals remain usable before the notes wave in isolation.
  Future<bool> liveNoteExists(String profileId, String noteId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM notes WHERE profile_id = ? AND id = ? '
          'AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(noteId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }
}
