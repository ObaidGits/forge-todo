import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';

/// An explicit optional value for partial updates.
///
/// The absence of an [Opt] (a `null` field) means "leave unchanged"; a present
/// `Opt(null)` means "clear this field". This distinguishes the two intents a
/// plain nullable field cannot.
final class Opt<T> {
  const Opt(this.value);
  final T value;
}

/// Input for creating a task (R-TASK-001). Only [title] and [lifeAreaId] are
/// required; everything else is progressively disclosed optional detail.
final class CreateTaskInput {
  const CreateTaskInput({
    required this.lifeAreaId,
    required this.title,
    this.priority = TaskPriority.none,
    this.scheduledDate,
    this.due = TaskDue.none,
    this.estimateMinutes,
    this.noteId,
    this.parentTaskId,
    this.tagIds = const <String>[],
    this.markInProgress = false,
  });

  final LifeAreaId lifeAreaId;
  final String title;
  final TaskPriority priority;
  final String? scheduledDate;
  final TaskDue due;
  final int? estimateMinutes;
  final NoteId? noteId;
  final TaskId? parentTaskId;
  final List<String> tagIds;

  /// Creates the task directly in the `in_progress` state instead of `open`.
  final bool markInProgress;
}

/// Input for patching a task (R-TASK-001, R-TASK-004, R-TASK-010). A `null`
/// field leaves the value unchanged; wrap clearable fields in [Opt].
final class UpdateTaskInput {
  const UpdateTaskInput({
    this.title,
    this.priority,
    this.due,
    this.scheduledDate,
    this.estimateMinutes,
    this.noteId,
    this.lifeAreaId,
  });

  final String? title;
  final TaskPriority? priority;

  /// A new due form; pass [TaskDue.none] to clear the due form.
  final TaskDue? due;

  final Opt<String?>? scheduledDate;
  final Opt<int?>? estimateMinutes;
  final Opt<NoteId?>? noteId;
  final LifeAreaId? lifeAreaId;

  bool get isEmpty =>
      title == null &&
      priority == null &&
      due == null &&
      scheduledDate == null &&
      estimateMinutes == null &&
      noteId == null &&
      lifeAreaId == null;
}

/// Input for moving/reordering a task (R-TASK-003, R-GEN-002).
///
/// [reparent], when present, changes the parent (possibly to `null` for a
/// top-level task). [beforeRank]/[afterRank] are the ranks of the immediate
/// neighbours the task is placed between; the new stable rank is generated
/// between them. Leaving both null keeps the current rank.
final class MoveTaskInput {
  const MoveTaskInput({this.reparent, this.beforeRank, this.afterRank});

  final Opt<TaskId?>? reparent;
  final String? beforeRank;
  final String? afterRank;
}
