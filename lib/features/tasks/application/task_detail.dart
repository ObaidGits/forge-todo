import 'package:forge/features/tasks/application/task_query_service.dart';

/// A presentation-safe detail projection of a single task (R-TASK-001,
/// R-TASK-003, R-TASK-004, R-TASK-005, R-TASK-010).
///
/// Like [TaskSummary], every field is a primitive or plain value so the detail
/// and editor screens never import the tasks domain model. Recurrence is
/// surfaced as presence plus a human-readable summary; subtasks and tags are
/// exposed as ready-to-render collections.
final class TaskDetail {
  const TaskDetail({
    required this.id,
    required this.title,
    required this.statusWire,
    required this.priorityWire,
    required this.priorityRank,
    required this.lifeAreaId,
    required this.isOverdue,
    required this.isRecurring,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.scheduledDate,
    this.dueDate,
    this.dueAtUtc,
    this.dueTimezoneId,
    this.estimateMinutes,
    this.noteId,
    this.parentTaskId,
    this.completedAtUtc,
    this.deletedAtUtc,
    this.tagIds = const <String>[],
    this.subtasks = const <TaskSummary>[],
  });

  final String id;
  final String title;
  final String statusWire;
  final String priorityWire;
  final int priorityRank;
  final String lifeAreaId;
  final bool isOverdue;
  final bool isRecurring;
  final int createdAtUtc;
  final int updatedAtUtc;

  final String? scheduledDate;
  final String? dueDate;
  final int? dueAtUtc;
  final String? dueTimezoneId;
  final int? estimateMinutes;
  final String? noteId;
  final String? parentTaskId;
  final int? completedAtUtc;
  final int? deletedAtUtc;
  final List<String> tagIds;
  final List<TaskSummary> subtasks;

  bool get isCompleted => statusWire == 'completed';
  bool get isCancelled => statusWire == 'cancelled';
  bool get isTerminal => isCompleted || isCancelled;
  bool get isDeleted => deletedAtUtc != null;
  bool get hasDueDate => dueDate != null;
  bool get hasDueInstant => dueAtUtc != null;
  bool get hasNote => noteId != null;
}
