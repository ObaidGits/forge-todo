import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// An immutable task aggregate (R-TASK-001, R-TASK-003, R-TASK-004, R-TASK-010).
///
/// A task is a top-level direct-area owner unless [parentTaskId] is set, in
/// which case it is a subtask inheriting its parent's area (data-model §1).
/// Notes are referenced through a canonical [noteId]; the task never stores an
/// inline note body (R-TASK-010). Recurrence linkage ([recurrenceRuleId],
/// [recurrenceVersion]) is populated by the recurrence engine (task 4.2) and is
/// null for a non-recurring task.
final class Task {
  Task({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.title,
    required this.status,
    required this.priority,
    required this.due,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.parentTaskId,
    this.scheduledDate,
    this.estimateMinutes,
    this.recurrenceRuleId,
    this.recurrenceVersion,
    this.completedAtUtc,
    this.noteId,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Task title must not be empty.');
    }
    if (scheduledDate != null && !_isoDate.hasMatch(scheduledDate!)) {
      throw FormatException('scheduled_date must be ISO YYYY-MM-DD.');
    }
    if (estimateMinutes != null && estimateMinutes! < 0) {
      throw const FormatException('estimate must be non-negative.');
    }
    final bool terminal = status.isTerminal;
    final bool hasCompletion = completedAtUtc != null;
    if (status == TaskStatus.completed && !hasCompletion) {
      throw const FormatException('A completed task requires completed_at.');
    }
    if (!terminal && hasCompletion) {
      throw const FormatException(
        'Only a terminal task may carry completed_at.',
      );
    }
  }

  final TaskId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final TaskId? parentTaskId;
  final String title;
  final TaskStatus status;
  final TaskPriority priority;

  /// Independent of [due]; a task may be scheduled for a working date without a
  /// deadline (R-TASK-004).
  final String? scheduledDate;

  /// The due form: none, a floating date, or an absolute instant (R-TASK-004).
  final TaskDue due;

  final int? estimateMinutes;
  final String? recurrenceRuleId;
  final int? recurrenceVersion;

  /// Completion instant in UTC microseconds; set only for terminal tasks.
  final int? completedAtUtc;

  /// Canonical note reference (R-TASK-010). Null when the task has no note.
  final NoteId? noteId;

  /// Stable manual ordering rank (R-TASK-003).
  final TaskRank rank;

  /// Semantic revision, incremented on each semantic row change (data-model
  /// §1). Used for sync field versioning.
  final int revision;

  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isSubtask => parentTaskId != null;
  bool get isDeleted => deletedAtUtc != null;

  static final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  Task copyWith({
    String? title,
    TaskStatus? status,
    TaskPriority? priority,
    Object? scheduledDate = _sentinel,
    TaskDue? due,
    Object? estimateMinutes = _sentinel,
    Object? noteId = _sentinel,
    Object? parentTaskId = _sentinel,
    LifeAreaId? lifeAreaId,
    Object? completedAtUtc = _sentinel,
    Object? recurrenceRuleId = _sentinel,
    Object? recurrenceVersion = _sentinel,
    TaskRank? rank,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return Task(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId ?? this.lifeAreaId,
      parentTaskId: parentTaskId == _sentinel
          ? this.parentTaskId
          : parentTaskId as TaskId?,
      title: title ?? this.title,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      scheduledDate: scheduledDate == _sentinel
          ? this.scheduledDate
          : scheduledDate as String?,
      due: due ?? this.due,
      estimateMinutes: estimateMinutes == _sentinel
          ? this.estimateMinutes
          : estimateMinutes as int?,
      recurrenceRuleId: recurrenceRuleId == _sentinel
          ? this.recurrenceRuleId
          : recurrenceRuleId as String?,
      recurrenceVersion: recurrenceVersion == _sentinel
          ? this.recurrenceVersion
          : recurrenceVersion as int?,
      completedAtUtc: completedAtUtc == _sentinel
          ? this.completedAtUtc
          : completedAtUtc as int?,
      noteId: noteId == _sentinel ? this.noteId : noteId as NoteId?,
      rank: rank ?? this.rank,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  /// Passed to [copyWith] for a clearable field to mean "leave unchanged",
  /// distinguishing it from passing `null` to clear the field.
  static const Object unchanged = _sentinel;

  static const Object _sentinel = Object();
}
