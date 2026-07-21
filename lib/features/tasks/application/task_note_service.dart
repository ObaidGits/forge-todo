import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';

/// The canonical note reference resolved for a task (R-TASK-010).
///
/// A task's notes are a single canonical [Note] addressed by `Task.noteId`;
/// there is no second inline text system. This value is what the "open task
/// note" flow returns: the [noteId] the caller navigates to, and whether that
/// note was freshly [created] by this call or an existing one was resolved.
final class TaskNoteRef {
  const TaskNoteRef({
    required this.taskId,
    required this.noteId,
    required this.created,
  });

  final String taskId;
  final String noteId;

  /// True when this call created the canonical note and bound it to the task;
  /// false when the task already referenced a note and it was resolved.
  final bool created;
}

/// Opens (or lazily creates) the canonical note behind a task (R-TASK-010).
///
/// This is an application-level integration contract: it composes the tasks and
/// notes feature contracts so a task's notes flow through one canonical [Note]
/// referenced by `Task.noteId`, with the note↔task `entity_link` maintained.
/// Implementations depend only on exported application contracts
/// ([NoteCommandService], [TaskCommandService], [TaskQueryService]) and never
/// on another feature's infrastructure (design.md §4).
abstract interface class TaskNoteService {
  /// Resolves the task's canonical note, creating and binding one when the task
  /// has no `note_id` yet.
  ///
  /// The operation is idempotent through [commandId]: a replay derives the same
  /// sub-command ids so it never creates a second note, a duplicate binding, or
  /// a duplicate link. When the task already references a note, the existing
  /// reference is returned and its note↔task link is re-asserted (a harmless
  /// idempotent no-op).
  ///
  /// Returns a [Failure] when the task does not exist for the profile, or when
  /// any composed command fails (the failure is surfaced verbatim).
  Future<Result<TaskNoteRef>> openOrCreateNote({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });
}
