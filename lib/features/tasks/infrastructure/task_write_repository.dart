import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/infrastructure/task_mapper.dart';

/// Transaction-scoped write access to the `tasks` table.
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes. All queries run
/// against [db]; while a Drift transaction is active they are routed to the
/// transaction executor automatically.
final class TaskWriteRepository {
  TaskWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Loads a task by id within the transaction, or null when it does not exist
  /// for [profileId] (regardless of soft-deletion state).
  Future<Task?> find(String profileId, String taskId) async {
    scope.ensureActive();
    final TaskRow? row =
        await (db.select(db.tasks)..where(
              (Tasks t) => t.profileId.equals(profileId) & t.id.equals(taskId),
            ))
            .getSingleOrNull();
    return row == null ? null : TaskMapper.fromRow(row);
  }

  Future<void> insert(Task task) async {
    scope.ensureActive();
    await db.into(db.tasks).insert(TaskMapper.toInsert(task));
  }

  /// Writes every mutable column of [task] for its `(profile_id, id)`.
  Future<void> update(Task task) async {
    scope.ensureActive();
    await (db.update(db.tasks)..where(
          (Tasks t) =>
              t.profileId.equals(task.profileId.value) &
              t.id.equals(task.id.value),
        ))
        .write(TaskMapper.toUpdate(task));
  }

  /// The highest existing sibling rank under [parentTaskId] (or among
  /// top-level tasks when null), used to append a new task at the end.
  Future<TaskRank?> lastSiblingRank(
    String profileId, {
    String? parentTaskId,
  }) async {
    scope.ensureActive();
    final String parentClause = parentTaskId == null
        ? 'parent_task_id IS NULL'
        : 'parent_task_id = ?';
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId),
      if (parentTaskId != null) Variable<String>(parentTaskId),
    ];
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM tasks WHERE profile_id = ? AND $parentClause '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: vars,
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return TaskRank(rows.single.data['rank'] as String);
  }

  /// The chain of ancestor ids from [taskId]'s parent upward to the root,
  /// parent first. Empty when [taskId] is top-level. Bounded by a recursive CTE
  /// depth guard so a corrupt cycle cannot loop unbounded.
  Future<List<String>> ancestorChain(String profileId, String taskId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'WITH RECURSIVE chain(id, parent_task_id, depth) AS ('
          '  SELECT id, parent_task_id, 0 FROM tasks '
          '    WHERE profile_id = ? AND id = ? '
          '  UNION ALL '
          '  SELECT t.id, t.parent_task_id, chain.depth + 1 FROM tasks t '
          '    JOIN chain ON t.id = chain.parent_task_id '
          '    WHERE t.profile_id = ? AND chain.depth < 64 '
          ') SELECT id FROM chain WHERE id <> ? ORDER BY depth ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(taskId),
            Variable<String>(profileId),
            Variable<String>(taskId),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  /// The depth of [taskId]'s own subtree (1 when it has no children).
  Future<int> subtreeDepth(String profileId, String taskId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'WITH RECURSIVE sub(id, depth) AS ('
          '  SELECT id, 1 FROM tasks WHERE profile_id = ? AND id = ? '
          '  UNION ALL '
          '  SELECT t.id, sub.depth + 1 FROM tasks t '
          '    JOIN sub ON t.parent_task_id = sub.id '
          '    WHERE t.profile_id = ? AND sub.depth < 64 '
          ') SELECT COALESCE(MAX(depth), 1) AS d FROM sub',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(taskId),
            Variable<String>(profileId),
          ],
        )
        .get();
    return rows.single.data['d'] as int;
  }

  /// Attaches [tagId] to a task through `entity_tags`. Idempotent per the
  /// composite primary key.
  Future<void> attachTag({
    required String profileId,
    required String taskId,
    required String tagId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT OR IGNORE INTO entity_tags '
      '(profile_id, entity_type, entity_id, tag_id, created_at_utc) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[profileId, 'task', taskId, tagId, nowUtc],
    );
  }

  /// The ids of every non-deleted task for [profileId], ordered stably. Used by
  /// the search source-rebuild path to regenerate task documents.
  Future<List<String>> activeIds(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM tasks WHERE profile_id = ? AND deleted_at_utc IS NULL '
          'ORDER BY id ASC',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  /// The current epoch stamped on outbox operations. Falls back to `0` before a
  /// sync profile link exists.
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
