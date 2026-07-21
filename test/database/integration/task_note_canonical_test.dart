import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_note_service.dart';

import 'notes_integration_support.dart';

/// Real Drift-backed integration proof that a task's notes flow through a single
/// canonical note referenced by `Task.noteId`, with the note↔task entity link
/// maintained — there is no second inline text system (R-TASK-010).
///
/// **Validates: Requirements R-TASK-010**
void main() {
  late NotesIntegrationHarness h;

  setUp(() async {
    h = await NotesIntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<TaskDetail> detail(String taskId) async {
    final TaskDetail? d = await h.taskQuery.detail(
      profileId: h.profileId,
      taskId: TaskId(taskId),
    );
    return d!;
  }

  test(
    'opening a task note creates a canonical note and binds Task.noteId',
    () async {
      final String taskId = await h.createTask('Ship release', seed: 'task');
      expect((await detail(taskId)).noteId, isNull);

      final Result<TaskNoteRef> result = await h.taskNotes.openOrCreateNote(
        commandId: h.nextCommandId('tn'),
        profileId: h.profileId,
        taskId: TaskId(taskId),
      );

      final TaskNoteRef ref = (result as Success<TaskNoteRef>).value;
      expect(ref.created, isTrue);
      expect(ref.taskId, taskId);

      // The task now references exactly the canonical note.
      final TaskDetail after = await detail(taskId);
      expect(after.noteId, ref.noteId);
      expect(after.hasNote, isTrue);

      // A single canonical note row exists (no second text system).
      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);

      // The note→task entity link is maintained both ways.
      final List<NoteEntityLink> forward = await h.noteReads.entityLinksOf(
        h.profileId,
        NoteId(ref.noteId),
      );
      expect(forward, hasLength(1));
      expect(forward.single.targetType, NoteEntityTargetType.task);
      expect(forward.single.targetId, taskId);

      final List<NoteEntityLink> reverse = await h.noteReads.notesLinkingTo(
        h.profileId,
        NoteEntityTargetType.task,
        taskId,
      );
      expect(reverse.single.noteId.value, ref.noteId);
    },
  );

  test(
    'replaying the same command resolves the same note, no duplicate',
    () async {
      final String taskId = await h.createTask('Plan sprint', seed: 'task');
      final CommandId cmd = h.nextCommandId('tn');

      final TaskNoteRef first =
          (await h.taskNotes.openOrCreateNote(
                    commandId: cmd,
                    profileId: h.profileId,
                    taskId: TaskId(taskId),
                  )
                  as Success<TaskNoteRef>)
              .value;
      final TaskNoteRef second =
          (await h.taskNotes.openOrCreateNote(
                    commandId: cmd,
                    profileId: h.profileId,
                    taskId: TaskId(taskId),
                  )
                  as Success<TaskNoteRef>)
              .value;

      expect(second.noteId, first.noteId);
      // Exactly one note and one link survive the replay.
      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM entity_links WHERE relation = 'note_reference'",
        ),
        1,
      );
    },
  );

  test(
    'a second open resolves the existing note instead of creating',
    () async {
      final String taskId = await h.createTask('Write spec', seed: 'task');

      final TaskNoteRef created =
          (await h.taskNotes.openOrCreateNote(
                    commandId: h.nextCommandId('tn1'),
                    profileId: h.profileId,
                    taskId: TaskId(taskId),
                  )
                  as Success<TaskNoteRef>)
              .value;
      expect(created.created, isTrue);

      final TaskNoteRef opened =
          (await h.taskNotes.openOrCreateNote(
                    commandId: h.nextCommandId('tn2'),
                    profileId: h.profileId,
                    taskId: TaskId(taskId),
                  )
                  as Success<TaskNoteRef>)
              .value;
      expect(opened.created, isFalse);
      expect(opened.noteId, created.noteId);
      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
    },
  );

  test('opening the note of a missing task fails without writing', () async {
    final Result<TaskNoteRef> result = await h.taskNotes.openOrCreateNote(
      commandId: h.nextCommandId('tn'),
      profileId: h.profileId,
      taskId: TaskId('018f0000-0000-7000-8000-ffffffffffff'),
    );
    expect(
      (result as Failed<TaskNoteRef>).failure.code,
      'task_note.task_not_found',
    );
    expect(await h.scalar('SELECT COUNT(*) FROM notes'), 0);
  });
}
