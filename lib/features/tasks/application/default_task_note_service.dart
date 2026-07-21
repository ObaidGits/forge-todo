import 'dart:convert';

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_command_service.dart';
import 'package:forge/features/notes/application/note_commands.dart' hide Opt;
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_note_service.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';

/// The note↔task `entity_link` target type (matches the notes feature's
/// `NoteEntityTargetType.task`). Declared as a literal here so the tasks
/// application depends only on the notes *application* contract, never its
/// domain/infrastructure (design.md §4 import rules).
const String _taskLinkTargetType = 'task';

/// Default [TaskNoteService] composed from the tasks and notes application
/// contracts (R-TASK-010).
///
/// Opening a task note resolves the canonical [Note] referenced by
/// `Task.noteId`. When the task has no note yet the service, in order:
/// 1. creates a canonical note (inheriting the task's Life Area and title),
/// 2. binds it to the task via `Task.noteId` (no second text system), and
/// 3. maintains the note↔task `entity_link`.
///
/// Every step runs through the durable command bus and is made idempotent by
/// deriving stable sub-command ids from the caller's [CommandId], so a replay
/// resolves the same note rather than creating another.
final class DefaultTaskNoteService implements TaskNoteService {
  const DefaultTaskNoteService({
    required this.tasks,
    required this.taskQuery,
    required this.notes,
  });

  final TaskCommandService tasks;
  final TaskQueryService taskQuery;
  final NoteCommandService notes;

  @override
  Future<Result<TaskNoteRef>> openOrCreateNote({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) async {
    final TaskDetail? detail = await taskQuery.detail(
      profileId: profileId,
      taskId: taskId,
    );
    if (detail == null) {
      return const Failed<TaskNoteRef>(
        Failure(
          kind: FailureKind.validation,
          code: 'task_note.task_not_found',
          safeMessageKey: 'error.validation',
          retryable: false,
        ),
      );
    }

    // Resolve an existing canonical note: re-assert its note↔task link so a
    // link lost to an earlier partial failure self-heals, then return it.
    if (detail.noteId != null) {
      final String existing = detail.noteId!;
      final Result<CommittedCommandResult> link = await notes.linkEntity(
        commandId: _sub(commandId, 'l'),
        profileId: profileId,
        noteId: NoteId(existing),
        targetType: _taskLinkTargetType,
        targetId: taskId.value,
      );
      return link.fold(
        success: (_) => Success<TaskNoteRef>(
          TaskNoteRef(taskId: taskId.value, noteId: existing, created: false),
        ),
        failure: (Failure f) => Failed<TaskNoteRef>(f),
      );
    }

    // Create the canonical note inheriting the task's area and title.
    final Result<CommittedCommandResult> created = await notes.create(
      commandId: _sub(commandId, 'n'),
      profileId: profileId,
      input: CreateNoteInput(
        lifeAreaId: LifeAreaId(detail.lifeAreaId),
        title: detail.title,
      ),
    );
    final CommittedCommandResult? createdOk = created.valueOrNull;
    if (createdOk == null) {
      return Failed<TaskNoteRef>(created.failureOrNull!);
    }
    final String? noteId = _idFromPayload(createdOk.resultPayload);
    if (noteId == null) {
      return const Failed<TaskNoteRef>(
        Failure(
          kind: FailureKind.unexpected,
          code: 'task_note.note_id_missing',
          safeMessageKey: 'error.unexpected',
          retryable: false,
        ),
      );
    }

    // Bind the canonical note to the task (R-TASK-010): a single reference,
    // never an inline body.
    final Result<CommittedCommandResult> bound = await tasks.update(
      commandId: _sub(commandId, 't'),
      profileId: profileId,
      taskId: taskId,
      input: UpdateTaskInput(noteId: Opt<NoteId?>(NoteId(noteId))),
    );
    if (bound.valueOrNull == null) {
      return Failed<TaskNoteRef>(bound.failureOrNull!);
    }

    // Maintain the note↔task entity link so backlinks resolve both ways.
    final Result<CommittedCommandResult> linked = await notes.linkEntity(
      commandId: _sub(commandId, 'l'),
      profileId: profileId,
      noteId: NoteId(noteId),
      targetType: _taskLinkTargetType,
      targetId: taskId.value,
    );
    if (linked.valueOrNull == null) {
      return Failed<TaskNoteRef>(linked.failureOrNull!);
    }

    return Success<TaskNoteRef>(
      TaskNoteRef(taskId: taskId.value, noteId: noteId, created: true),
    );
  }

  /// Derives a stable sub-command id so the composed multi-command operation is
  /// idempotent on replay (R-GEN-005).
  CommandId _sub(CommandId base, String suffix) =>
      CommandId('${base.value}-$suffix');

  static String? _idFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map<String, Object?> && decoded['id'] is String) {
      return decoded['id'] as String;
    }
    return null;
  }
}
