import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_views.dart';

/// A presentation-safe read projection of a task (R-TASK-002, R-HOME-001).
///
/// This is the tasks feature's *exported application contract*: other features
/// (for example Home) compose it without importing the tasks domain model or
/// its Drift infrastructure (design.md §4). All fields are primitives or plain
/// value types so a consumer never needs a tasks-domain import.
final class TaskSummary {
  const TaskSummary({
    required this.id,
    required this.title,
    required this.statusWire,
    required this.priorityWire,
    required this.priorityRank,
    required this.rank,
    required this.isOverdue,
    this.scheduledDate,
    this.dueDate,
    this.dueAtUtc,
    this.dueTimezoneId,
    this.completedAtUtc,
    this.hasNote = false,
  });

  final String id;
  final String title;

  /// Stable status wire value: `open`, `in_progress`, `completed`, `cancelled`.
  final String statusWire;

  /// Stable priority wire value: `none`, `low`, `medium`, `high`, `urgent`.
  final String priorityWire;

  /// Numeric priority ordering (urgent highest) for deterministic sorting.
  final int priorityRank;

  /// Stable manual ordering rank.
  final String rank;

  /// True when the task is open/in-progress and its due point is in the past
  /// relative to the caller's planning date / trusted now (R-TASK-004).
  final bool isOverdue;

  final String? scheduledDate;
  final String? dueDate;
  final int? dueAtUtc;
  final String? dueTimezoneId;
  final int? completedAtUtc;
  final bool hasNote;

  bool get isCompleted => statusWire == 'completed';
  bool get hasDueTime => dueAtUtc != null;
}

/// The Today agenda split into the calm buckets a Home view needs
/// (ux-design §8): overdue first, then tasks due/scheduled today, plus the
/// tasks already completed within the current planning day.
final class TodayAgenda {
  const TodayAgenda({
    required this.overdue,
    required this.dueToday,
    required this.completedToday,
  });

  const TodayAgenda.empty()
    : overdue = const <TaskSummary>[],
      dueToday = const <TaskSummary>[],
      completedToday = const <TaskSummary>[];

  final List<TaskSummary> overdue;
  final List<TaskSummary> dueToday;
  final List<TaskSummary> completedToday;

  /// The eligible-today set: actionable (overdue + due today) plus already
  /// completed today. Used as the progress-ring denominator.
  int get plannedTotal =>
      overdue.length + dueToday.length + completedToday.length;

  bool get isEmpty => plannedTotal == 0;
}

/// Exported read contract for building the Today agenda (R-TASK-002).
///
/// Reads run against the active local Drift generation, the client source of
/// truth (design.md §8), so the agenda is always available offline
/// (R-GEN-001, R-HOME-005).
abstract interface class TaskQueryService {
  /// Returns the Today agenda for [profileId].
  ///
  /// [currentPlanningDate] is the ISO `YYYY-MM-DD` planning day; a date-only
  /// task is overdue once that boundary has passed after its due date.
  /// [nowUtcMicros] is trusted current time in UTC microseconds; an instant
  /// task is overdue when it exceeds this. [dayStartUtcMicros] bounds the
  /// "completed today" set to completions at or after the planning day's start.
  Future<TodayAgenda> todayAgenda({
    required ProfileId profileId,
    required String currentPlanningDate,
    required int dayStartUtcMicros,
    required int nowUtcMicros,
    LifeAreaId? lifeAreaId,
  });

  /// Lists the tasks in [view], narrowed by an optional composable [filter]
  /// (R-TASK-002, R-TASK-008). The Today and Upcoming views require
  /// [currentPlanningDate] and [nowUtcMicros] to classify by the R-TASK-004
  /// overdue boundary; other views ignore them. Each summary's [TaskSummary.isOverdue]
  /// is computed against the same boundary. Results are stably ordered:
  /// completed/trash by recency, everything else by priority then manual rank.
  Future<List<TaskSummary>> list({
    required ProfileId profileId,
    required TaskListView view,
    TaskFilter filter = const TaskFilter(),
    String? currentPlanningDate,
    int? dayStartUtcMicros,
    int? nowUtcMicros,
  });

  /// Returns the full detail projection for [taskId], or null when it does not
  /// exist for [profileId]. [currentPlanningDate]/[nowUtcMicros] classify the
  /// overdue flag; when omitted the flag is derived only from a date-only due
  /// against `null` (i.e. reported not overdue).
  Future<TaskDetail?> detail({
    required ProfileId profileId,
    required TaskId taskId,
    String? currentPlanningDate,
    int? nowUtcMicros,
  });
}
