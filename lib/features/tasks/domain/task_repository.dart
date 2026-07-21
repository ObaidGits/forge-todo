import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Named task view (R-TASK-002).
enum TaskViewKind {
  /// Overdue plus tasks scheduled or due today.
  today,

  /// Future scheduled/due tasks.
  upcoming,

  /// Tasks with neither a scheduled date nor a due form.
  inbox,

  /// Completed tasks, newest completion first.
  completed,

  /// Soft-deleted tasks.
  trash,
}

/// A composable structured task filter (R-TASK-008).
///
/// Every field is optional and combined with logical AND. Free [titleContains]
/// text is a simple substring fallback here; the FTS-backed contributor lands
/// with the search wave (task 4.6).
final class TaskQuery {
  const TaskQuery({
    this.statuses,
    this.lifeAreaId,
    this.priorities,
    this.dueFromDate,
    this.dueToDate,
    this.dueFromUtc,
    this.dueToUtc,
    this.scheduledFromDate,
    this.scheduledToDate,
    this.tagId,
    this.hasRecurrence,
    this.relation,
    this.parentTaskId,
    this.onlyTopLevel = false,
    this.titleContains,
    this.includeDeleted = false,
    this.onlyDeleted = false,
    this.limit,
  });

  final Set<TaskStatus>? statuses;
  final LifeAreaId? lifeAreaId;
  final Set<TaskPriority>? priorities;

  /// Inclusive floating-date range over `due_date`.
  final String? dueFromDate;
  final String? dueToDate;

  /// Inclusive instant range (UTC microseconds) over `due_at_utc`.
  final int? dueFromUtc;
  final int? dueToUtc;

  /// Inclusive floating-date range over `scheduled_date`.
  final String? scheduledFromDate;
  final String? scheduledToDate;

  final String? tagId;

  /// When set, filters on whether the task is part of a recurrence series.
  final bool? hasRecurrence;

  /// Restricts to tasks linked to another entity through `entity_links`
  /// (goal, Learning Resource, habit, ...).
  final TaskRelationFilter? relation;

  /// Restricts to direct children of a specific parent.
  final TaskId? parentTaskId;

  /// Restricts to top-level tasks (no parent).
  final bool onlyTopLevel;

  final String? titleContains;

  /// Includes soft-deleted rows in the result.
  final bool includeDeleted;

  /// Restricts strictly to soft-deleted rows (the Trash view).
  final bool onlyDeleted;

  final int? limit;
}

/// A relation filter against `entity_links` (R-TASK-008).
final class TaskRelationFilter {
  const TaskRelationFilter({
    required this.relation,
    required this.targetType,
    required this.targetId,
  });

  /// The link relation, e.g. `belongs_to_goal`, `supports_habit`.
  final String relation;
  final String targetType;
  final String targetId;
}

/// Read access to tasks. Query methods run outside a write transaction and
/// return immutable domain [Task] aggregates.
abstract interface class TaskRepository {
  Future<Task?> findById(ProfileId profileId, TaskId taskId);

  Future<List<Task>> query(ProfileId profileId, TaskQuery filter);

  Future<List<Task>> view(
    ProfileId profileId,
    TaskViewKind kind, {
    LifeAreaId? lifeAreaId,
    String? currentPlanningDate,
    int? nowUtcMicros,
  });

  /// The highest existing sibling rank under [parentTaskId] (or among
  /// top-level tasks when null), used to append a new task at the end.
  Future<TaskRank?> lastSiblingRank(
    ProfileId profileId, {
    TaskId? parentTaskId,
  });

  /// The direct, non-deleted child tasks of [parentTaskId], ordered by rank.
  Future<List<Task>> childrenOf(ProfileId profileId, TaskId parentTaskId);

  /// The ids of the tags linked to [taskId] through `entity_tags`.
  Future<List<String>> tagIdsFor(ProfileId profileId, TaskId taskId);

  /// The chain of ancestor ids from [taskId]'s parent upward to the root,
  /// parent first. Empty when [taskId] is top-level.
  Future<List<String>> ancestorChain(ProfileId profileId, TaskId taskId);

  /// The depth of [taskId]'s own subtree (1 when it has no children).
  Future<int> subtreeDepth(ProfileId profileId, TaskId taskId);
}
