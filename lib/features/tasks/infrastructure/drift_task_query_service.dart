import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_repository.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Drift-backed [TaskQueryService] built on the tasks read repository
/// (R-TASK-002, R-HOME-001).
///
/// It classifies the active Today set into overdue versus due-today buckets
/// using the exact R-TASK-004 boundary and derives "completed today" from the
/// completion instant. Everything is reconstructed from the local generation,
/// so the agenda is fully available offline (R-GEN-001).
final class DriftTaskQueryService implements TaskQueryService {
  DriftTaskQueryService(this._reads);

  final TaskRepository _reads;

  @override
  Future<TodayAgenda> todayAgenda({
    required ProfileId profileId,
    required String currentPlanningDate,
    required int dayStartUtcMicros,
    required int nowUtcMicros,
    LifeAreaId? lifeAreaId,
  }) async {
    // Classify the active set directly so a task due *later today* (an instant
    // between now and the day boundary) still surfaces on Today, which the
    // already-due-only Today view (R-TASK-002) would omit.
    final int dayEndUtcMicros =
        dayStartUtcMicros + const Duration(days: 1).inMicroseconds;
    final List<Task> active = await _reads.query(
      profileId,
      TaskQuery(
        lifeAreaId: lifeAreaId,
        statuses: const <TaskStatus>{TaskStatus.open, TaskStatus.inProgress},
      ),
    );

    final List<TaskSummary> overdue = <TaskSummary>[];
    final List<TaskSummary> dueToday = <TaskSummary>[];
    for (final Task task in active) {
      if (!_isActionableToday(task, currentPlanningDate, dayEndUtcMicros)) {
        continue;
      }
      final bool isOverdue = _isOverdue(
        task,
        currentPlanningDate,
        nowUtcMicros,
      );
      final TaskSummary summary = _summary(task, isOverdue: isOverdue);
      (isOverdue ? overdue : dueToday).add(summary);
    }

    final List<Task> completed = await _reads.query(
      profileId,
      TaskQuery(
        lifeAreaId: lifeAreaId,
        statuses: const <TaskStatus>{TaskStatus.completed},
      ),
    );
    final List<TaskSummary> completedToday = completed
        .where((Task t) => (t.completedAtUtc ?? -1) >= dayStartUtcMicros)
        .map((Task t) => _summary(t, isOverdue: false))
        .toList(growable: false);

    overdue.sort(_byPriorityThenRank);
    dueToday.sort(_byPriorityThenRank);
    completedToday.sort(_byCompletionDesc);

    return TodayAgenda(
      overdue: overdue,
      dueToday: dueToday,
      completedToday: completedToday,
    );
  }

  @override
  Future<List<TaskSummary>> list({
    required ProfileId profileId,
    required TaskListView view,
    TaskFilter filter = const TaskFilter(),
    String? currentPlanningDate,
    int? dayStartUtcMicros,
    int? nowUtcMicros,
  }) async {
    final List<Task> rows = await _reads.query(
      profileId,
      _queryFor(view, filter),
    );

    switch (view) {
      case TaskListView.completed:
        final List<TaskSummary> summaries = rows
            .map((Task t) => _summary(t, isOverdue: false))
            .toList(growable: false);
        return summaries..sort(_byCompletionDesc);
      case TaskListView.trash:
        // The repository already orders trashed rows by deletion recency.
        return rows
            .map((Task t) => _summary(t, isOverdue: false))
            .toList(growable: false);
      case TaskListView.inbox:
        final List<TaskSummary> summaries = rows
            .where((Task t) => t.scheduledDate == null && !t.due.hasDue)
            .map((Task t) => _summary(t, isOverdue: false))
            .toList(growable: false);
        return summaries..sort(_byPriorityThenRank);
      case TaskListView.today:
        final String cpd = _require(currentPlanningDate, 'currentPlanningDate');
        final int now = _require(nowUtcMicros, 'nowUtcMicros');
        final int dayEnd = dayStartUtcMicros == null
            ? now
            : dayStartUtcMicros + const Duration(days: 1).inMicroseconds;
        final List<TaskSummary> summaries = <TaskSummary>[];
        for (final Task task in rows) {
          if (!_isActionableToday(task, cpd, dayEnd)) {
            continue;
          }
          summaries.add(_summary(task, isOverdue: _isOverdue(task, cpd, now)));
        }
        return summaries..sort(_todayOrder);
      case TaskListView.upcoming:
        final String cpd = _require(currentPlanningDate, 'currentPlanningDate');
        final int now = _require(nowUtcMicros, 'nowUtcMicros');
        final int dayEnd = dayStartUtcMicros == null
            ? now
            : dayStartUtcMicros + const Duration(days: 1).inMicroseconds;
        final List<TaskSummary> summaries = rows
            .where(
              (Task t) =>
                  !_isActionableToday(t, cpd, dayEnd) &&
                  (t.scheduledDate != null || t.due.hasDue),
            )
            .map((Task t) => _summary(t, isOverdue: false))
            .toList(growable: false);
        return summaries..sort(_byUpcomingDate);
    }
  }

  @override
  Future<TaskDetail?> detail({
    required ProfileId profileId,
    required TaskId taskId,
    String? currentPlanningDate,
    int? nowUtcMicros,
  }) async {
    final Task? task = await _reads.findById(profileId, taskId);
    if (task == null) {
      return null;
    }
    final List<String> tagIds = await _reads.tagIdsFor(profileId, taskId);
    final List<Task> children = await _reads.childrenOf(profileId, taskId);
    final bool overdue =
        currentPlanningDate != null &&
        nowUtcMicros != null &&
        _isOverdue(task, currentPlanningDate, nowUtcMicros);
    final List<TaskSummary> subtasks =
        (children.map((Task c) => _summary(c, isOverdue: false)).toList()
          ..sort(_byPriorityThenRank));
    return TaskDetail(
      id: task.id.value,
      title: task.title,
      statusWire: task.status.wire,
      priorityWire: task.priority.wire,
      priorityRank: task.priority.rank,
      lifeAreaId: task.lifeAreaId.value,
      isOverdue: overdue,
      isRecurring: task.recurrenceRuleId != null,
      createdAtUtc: task.createdAtUtc,
      updatedAtUtc: task.updatedAtUtc,
      scheduledDate: task.scheduledDate,
      dueDate: task.due.dueDate,
      dueAtUtc: task.due.dueAtUtc,
      dueTimezoneId: task.due.timezoneId,
      estimateMinutes: task.estimateMinutes,
      noteId: task.noteId?.value,
      parentTaskId: task.parentTaskId?.value,
      completedAtUtc: task.completedAtUtc,
      deletedAtUtc: task.deletedAtUtc,
      tagIds: tagIds,
      subtasks: subtasks,
    );
  }

  /// Builds the structured [TaskQuery] for a view plus composable filter.
  TaskQuery _queryFor(TaskListView view, TaskFilter filter) {
    final Set<TaskStatus>? filterStatuses = filter.statusWires.isEmpty
        ? null
        : filter.statusWires.map(TaskStatus.fromWire).toSet();

    Set<TaskStatus>? statuses;
    bool onlyDeleted = false;
    switch (view) {
      case TaskListView.completed:
        statuses = const <TaskStatus>{TaskStatus.completed};
      case TaskListView.trash:
        onlyDeleted = true;
      case TaskListView.inbox:
      case TaskListView.today:
      case TaskListView.upcoming:
        const Set<TaskStatus> active = <TaskStatus>{
          TaskStatus.open,
          TaskStatus.inProgress,
        };
        statuses = filterStatuses == null
            ? active
            : active.intersection(filterStatuses);
    }

    final Set<TaskPriority>? priorities = filter.priorityWires.isEmpty
        ? null
        : filter.priorityWires.map(TaskPriority.fromWire).toSet();

    return TaskQuery(
      statuses: statuses,
      onlyDeleted: onlyDeleted,
      lifeAreaId: filter.lifeAreaId,
      priorities: priorities,
      tagId: filter.tagId,
      hasRecurrence: filter.hasRecurrence,
      relation: filter.relation == null
          ? null
          : TaskRelationFilter(
              relation: filter.relation!.relation,
              targetType: filter.relation!.targetType,
              targetId: filter.relation!.targetId,
            ),
      titleContains: (filter.text != null && filter.text!.trim().isNotEmpty)
          ? filter.text!.trim()
          : null,
      dueFromDate: filter.dueFromDate,
      dueToDate: filter.dueToDate,
    );
  }

  /// A task belongs on Today when it is scheduled on/before the planning day,
  /// its floating due date is on/before the planning day, or its instant due
  /// falls anywhere up to the end of the planning day (ux-design §8). Future
  /// dates/instants are Upcoming, not Today.
  bool _isActionableToday(
    Task task,
    String currentPlanningDate,
    int dayEndUtcMicros,
  ) {
    final String? scheduled = task.scheduledDate;
    if (scheduled != null && scheduled.compareTo(currentPlanningDate) <= 0) {
      return true;
    }
    final String? dueDate = task.due.dueDate;
    if (dueDate != null && dueDate.compareTo(currentPlanningDate) <= 0) {
      return true;
    }
    final int? dueAt = task.due.dueAtUtc;
    return dueAt != null && dueAt < dayEndUtcMicros;
  }

  /// R-TASK-004: an open/in-progress date-only task is overdue once the
  /// planning-day boundary has passed after its due date; an instant task is
  /// overdue when trusted now exceeds `due_at`. Terminal tasks are never
  /// overdue. `scheduled_date` never makes a task overdue.
  bool _isOverdue(Task task, String currentPlanningDate, int nowUtcMicros) {
    if (task.status.isTerminal) {
      return false;
    }
    final String? dueDate = task.due.dueDate;
    if (dueDate != null && dueDate.compareTo(currentPlanningDate) < 0) {
      return true;
    }
    final int? dueAt = task.due.dueAtUtc;
    return dueAt != null && dueAt < nowUtcMicros;
  }

  TaskSummary _summary(Task task, {required bool isOverdue}) {
    return TaskSummary(
      id: task.id.value,
      title: task.title,
      statusWire: task.status.wire,
      priorityWire: task.priority.wire,
      priorityRank: task.priority.rank,
      rank: task.rank.value,
      isOverdue: isOverdue,
      scheduledDate: task.scheduledDate,
      dueDate: task.due.dueDate,
      dueAtUtc: task.due.dueAtUtc,
      dueTimezoneId: task.due.timezoneId,
      completedAtUtc: task.completedAtUtc,
      hasNote: task.noteId != null,
    );
  }

  static int _byPriorityThenRank(TaskSummary a, TaskSummary b) {
    final int byPriority = b.priorityRank.compareTo(a.priorityRank);
    if (byPriority != 0) {
      return byPriority;
    }
    final int byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.id.compareTo(b.id);
  }

  static int _byCompletionDesc(TaskSummary a, TaskSummary b) {
    final int byTime = (b.completedAtUtc ?? 0).compareTo(a.completedAtUtc ?? 0);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  static T _require<T>(T? value, String name) {
    if (value == null) {
      throw ArgumentError.notNull(name);
    }
    return value;
  }

  /// Today order: overdue tasks first, then by priority then manual rank.
  static int _todayOrder(TaskSummary a, TaskSummary b) {
    if (a.isOverdue != b.isOverdue) {
      return a.isOverdue ? -1 : 1;
    }
    return _byPriorityThenRank(a, b);
  }

  /// Upcoming order: earliest due date/instant first, then priority then rank.
  static int _byUpcomingDate(TaskSummary a, TaskSummary b) {
    final String? ak = _upcomingKey(a);
    final String? bk = _upcomingKey(b);
    if (ak != null && bk != null && ak != bk) {
      return ak.compareTo(bk);
    }
    if (ak == null && bk != null) {
      return 1;
    }
    if (ak != null && bk == null) {
      return -1;
    }
    return _byPriorityThenRank(a, b);
  }

  /// A comparable key for upcoming ordering: due date, then a padded instant,
  /// then scheduled date.
  static String? _upcomingKey(TaskSummary s) {
    if (s.dueDate != null) {
      return 'd:${s.dueDate}';
    }
    if (s.dueAtUtc != null) {
      return 'i:${s.dueAtUtc.toString().padLeft(20, '0')}';
    }
    if (s.scheduledDate != null) {
      return 's:${s.scheduledDate}';
    }
    return null;
  }
}
