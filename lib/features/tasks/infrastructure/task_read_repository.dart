import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_repository.dart';
import 'package:forge/features/tasks/domain/task_status.dart';
import 'package:forge/features/tasks/infrastructure/task_mapper.dart';

/// Drift-backed read model for tasks (R-TASK-002, R-TASK-008).
///
/// Reads run against the active local generation, which is the client source of
/// truth (design.md §8). Structured filters compose with AND; free-text is a
/// simple `LIKE` fallback until the FTS contributor lands (task 4.6).
final class TaskReadRepository implements TaskRepository {
  TaskReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<Task?> findById(ProfileId profileId, TaskId taskId) async {
    final TaskRow? row =
        await (_db.select(_db.tasks)..where(
              (Tasks t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(taskId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : TaskMapper.fromRow(row);
  }

  @override
  Future<List<Task>> query(ProfileId profileId, TaskQuery filter) async {
    final _WhereClause where = _buildWhere(profileId, filter);
    final String order = filter.onlyDeleted
        ? 'ORDER BY deleted_at_utc DESC, id DESC'
        : 'ORDER BY rank ASC, id ASC';
    final String limit = filter.limit == null ? '' : 'LIMIT ${filter.limit}';
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM tasks WHERE ${where.sql} $order $limit',
          variables: where.variables,
        )
        .get();
    return rows
        .map((QueryRow r) => TaskMapper.fromRow(_db.tasks.map(r.data)))
        .toList(growable: false);
  }

  @override
  Future<List<Task>> view(
    ProfileId profileId,
    TaskViewKind kind, {
    LifeAreaId? lifeAreaId,
    String? currentPlanningDate,
    int? nowUtcMicros,
  }) async {
    switch (kind) {
      case TaskViewKind.completed:
        return query(
          profileId,
          TaskQuery(
            lifeAreaId: lifeAreaId,
            statuses: const <TaskStatus>{TaskStatus.completed},
          ),
        ).then(_sortByCompletion);
      case TaskViewKind.trash:
        return query(
          profileId,
          TaskQuery(lifeAreaId: lifeAreaId, onlyDeleted: true),
        );
      case TaskViewKind.inbox:
        final List<Task> all = await query(
          profileId,
          TaskQuery(
            lifeAreaId: lifeAreaId,
            statuses: const <TaskStatus>{
              TaskStatus.open,
              TaskStatus.inProgress,
            },
          ),
        );
        return all
            .where((Task t) => t.scheduledDate == null && !t.due.hasDue)
            .toList(growable: false);
      case TaskViewKind.today:
      case TaskViewKind.upcoming:
        final String cpd = _require(currentPlanningDate, 'currentPlanningDate');
        final int now = _require(nowUtcMicros, 'nowUtcMicros');
        final List<Task> active = await query(
          profileId,
          TaskQuery(
            lifeAreaId: lifeAreaId,
            statuses: const <TaskStatus>{
              TaskStatus.open,
              TaskStatus.inProgress,
            },
          ),
        );
        bool isTodayOrPast(Task t) {
          final String? sd = t.scheduledDate;
          final String? dd = t.due.dueDate;
          final int? da = t.due.dueAtUtc;
          final bool scheduledNow = sd != null && sd.compareTo(cpd) <= 0;
          final bool dueDateNow = dd != null && dd.compareTo(cpd) <= 0;
          final bool dueAtNow = da != null && da <= now;
          return scheduledNow || dueDateNow || dueAtNow;
        }

        return active
            .where(
              (Task t) => kind == TaskViewKind.today
                  ? isTodayOrPast(t)
                  : !isTodayOrPast(t) &&
                        (t.scheduledDate != null || t.due.hasDue),
            )
            .toList(growable: false);
    }
  }

  @override
  Future<TaskRank?> lastSiblingRank(
    ProfileId profileId, {
    TaskId? parentTaskId,
  }) async {
    final String parentClause = parentTaskId == null
        ? 'parent_task_id IS NULL'
        : 'parent_task_id = ?';
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
      if (parentTaskId != null) Variable<String>(parentTaskId.value),
    ];
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT rank FROM tasks WHERE profile_id = ? AND $parentClause '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: vars,
        )
        .get();
    return rows.isEmpty ? null : TaskRank(rows.single.data['rank'] as String);
  }

  @override
  Future<List<Task>> childrenOf(
    ProfileId profileId,
    TaskId parentTaskId,
  ) async {
    return query(profileId, TaskQuery(parentTaskId: parentTaskId));
  }

  @override
  Future<List<String>> tagIdsFor(ProfileId profileId, TaskId taskId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT tag_id FROM entity_tags '
          "WHERE profile_id = ? AND entity_type = 'task' AND entity_id = ? "
          'ORDER BY tag_id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(taskId.value),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['tag_id'] as String)
        .toList(growable: false);
  }

  @override
  Future<List<String>> ancestorChain(ProfileId profileId, TaskId taskId) async {
    final List<QueryRow> rows = await _db
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
            Variable<String>(profileId.value),
            Variable<String>(taskId.value),
            Variable<String>(profileId.value),
            Variable<String>(taskId.value),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  @override
  Future<int> subtreeDepth(ProfileId profileId, TaskId taskId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'WITH RECURSIVE sub(id, depth) AS ('
          '  SELECT id, 1 FROM tasks WHERE profile_id = ? AND id = ? '
          '  UNION ALL '
          '  SELECT t.id, sub.depth + 1 FROM tasks t '
          '    JOIN sub ON t.parent_task_id = sub.id '
          '    WHERE t.profile_id = ? AND sub.depth < 64 '
          ') SELECT COALESCE(MAX(depth), 1) AS d FROM sub',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(taskId.value),
            Variable<String>(profileId.value),
          ],
        )
        .get();
    return rows.single.data['d'] as int;
  }

  List<Task> _sortByCompletion(List<Task> tasks) {
    final List<Task> sorted = List<Task>.of(tasks)
      ..sort((Task a, Task b) {
        final int ac = a.completedAtUtc ?? 0;
        final int bc = b.completedAtUtc ?? 0;
        final int byTime = bc.compareTo(ac);
        return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
      });
    return sorted;
  }

  _WhereClause _buildWhere(ProfileId profileId, TaskQuery f) {
    final List<String> clauses = <String>['profile_id = ?'];
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
    ];

    if (f.onlyDeleted) {
      clauses.add('deleted_at_utc IS NOT NULL');
    } else if (!f.includeDeleted) {
      clauses.add('deleted_at_utc IS NULL');
    }

    final Set<TaskStatus>? statuses = f.statuses;
    if (statuses != null && statuses.isNotEmpty) {
      final String placeholders = List<String>.filled(
        statuses.length,
        '?',
      ).join(', ');
      clauses.add('status IN ($placeholders)');
      for (final TaskStatus s in statuses) {
        vars.add(Variable<String>(s.wire));
      }
    }

    if (f.lifeAreaId != null) {
      clauses.add('life_area_id = ?');
      vars.add(Variable<String>(f.lifeAreaId!.value));
    }

    final Set<TaskPriority>? priorities = f.priorities;
    if (priorities != null && priorities.isNotEmpty) {
      final String placeholders = List<String>.filled(
        priorities.length,
        '?',
      ).join(', ');
      clauses.add('priority IN ($placeholders)');
      for (final TaskPriority p in priorities) {
        vars.add(Variable<String>(p.wire));
      }
    }

    if (f.dueFromDate != null) {
      clauses.add('due_date >= ?');
      vars.add(Variable<String>(f.dueFromDate!));
    }
    if (f.dueToDate != null) {
      clauses.add('due_date <= ?');
      vars.add(Variable<String>(f.dueToDate!));
    }
    if (f.dueFromUtc != null) {
      clauses.add('due_at_utc >= ?');
      vars.add(Variable<int>(f.dueFromUtc!));
    }
    if (f.dueToUtc != null) {
      clauses.add('due_at_utc <= ?');
      vars.add(Variable<int>(f.dueToUtc!));
    }
    if (f.scheduledFromDate != null) {
      clauses.add('scheduled_date >= ?');
      vars.add(Variable<String>(f.scheduledFromDate!));
    }
    if (f.scheduledToDate != null) {
      clauses.add('scheduled_date <= ?');
      vars.add(Variable<String>(f.scheduledToDate!));
    }

    if (f.hasRecurrence != null) {
      clauses.add(
        f.hasRecurrence!
            ? 'recurrence_rule_id IS NOT NULL'
            : 'recurrence_rule_id IS NULL',
      );
    }

    if (f.parentTaskId != null) {
      clauses.add('parent_task_id = ?');
      vars.add(Variable<String>(f.parentTaskId!.value));
    } else if (f.onlyTopLevel) {
      clauses.add('parent_task_id IS NULL');
    }

    if (f.titleContains != null && f.titleContains!.isNotEmpty) {
      clauses.add(
        'title LIKE ? ESCAPE '
        r"'\'",
      );
      vars.add(Variable<String>('%${_escapeLike(f.titleContains!)}%'));
    }

    if (f.tagId != null) {
      clauses.add(
        'id IN (SELECT entity_id FROM entity_tags '
        "WHERE profile_id = ? AND entity_type = 'task' AND tag_id = ?)",
      );
      vars
        ..add(Variable<String>(profileId.value))
        ..add(Variable<String>(f.tagId!));
    }

    final TaskRelationFilter? rel = f.relation;
    if (rel != null) {
      clauses.add(
        'id IN (SELECT from_id FROM entity_links '
        "WHERE profile_id = ? AND from_type = 'task' "
        'AND relation = ? AND to_type = ? AND to_id = ?)',
      );
      vars
        ..add(Variable<String>(profileId.value))
        ..add(Variable<String>(rel.relation))
        ..add(Variable<String>(rel.targetType))
        ..add(Variable<String>(rel.targetId));
    }

    return _WhereClause(clauses.join(' AND '), vars);
  }

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static T _require<T>(T? value, String name) {
    if (value == null) {
      throw ArgumentError.notNull(name);
    }
    return value;
  }
}

final class _WhereClause {
  const _WhereClause(this.sql, this.variables);

  final String sql;
  final List<Variable<Object>> variables;
}
