import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';

import 'note_test_support.dart';

/// Real Drift-backed tests for note→entity links with profile ownership
/// enforcement and cross-profile rejection (R-NOTE-002, R-GEN-002).
///
/// **Validates: Requirements R-NOTE-003, R-GEN-002**
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('linking a note to an owned entity (R-NOTE-002)', () {
    test('links to a same-profile task and navigates both ways', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final String task = await h.insertRawTask(id: 'task-1');

      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.task,
        task,
        seed: 'lk',
      );
      expect(result, isA<Success<CommittedCommandResult>>());

      final List<NoteEntityLink> forward = await h.reads.entityLinksOf(
        h.profileId,
        NoteId(note),
      );
      expect(forward, hasLength(1));
      expect(forward.single.targetType, NoteEntityTargetType.task);
      expect(forward.single.targetId, task);

      final List<NoteEntityLink> reverse = await h.reads.notesLinkingTo(
        h.profileId,
        NoteEntityTargetType.task,
        task,
      );
      expect(reverse, hasLength(1));
      expect(reverse.single.noteId.value, note);
    });

    test('re-linking the same tuple is an idempotent no-op', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final String task = await h.insertRawTask(id: 'task-1');
      await h.linkEntity(note, NoteEntityTargetType.task, task, seed: 'a');
      await h.linkEntity(note, NoteEntityTargetType.task, task, seed: 'b');
      expect(
        await h.reads.entityLinksOf(h.profileId, NoteId(note)),
        hasLength(1),
      );
    });

    test('unlink removes the link and is idempotent', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final String task = await h.insertRawTask(id: 'task-1');
      await h.linkEntity(note, NoteEntityTargetType.task, task, seed: 'a');

      await h.unlinkEntity(note, NoteEntityTargetType.task, task, seed: 'u1');
      expect(await h.reads.entityLinksOf(h.profileId, NoteId(note)), isEmpty);
      // Unlinking again is harmless.
      final Result<CommittedCommandResult> again = await h.unlinkEntity(
        note,
        NoteEntityTargetType.task,
        task,
        seed: 'u2',
      );
      expect(again, isA<Success<CommittedCommandResult>>());
    });
  });

  group('ownership enforcement and cross-profile rejection (R-GEN-002)', () {
    test('a task owned by another profile is rejected', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final String foreign = await h.insertForeignProfile();
      final String foreignTask = await h.insertRawTask(
        id: 'task-foreign',
        ownerProfileId: foreign,
        areaId: 'area-2',
      );

      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.task,
        foreignTask,
        seed: 'x',
      );
      final Failure failure =
          (result as Failed<CommittedCommandResult>).failure;
      expect(failure.code, 'note.entity_target_not_found');
      // No cross-profile row was written.
      expect(await h.scalar('SELECT COUNT(*) FROM entity_links'), 0);
    });

    test('a non-existent target is rejected', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.task,
        'ghost-task',
        seed: 'x',
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'note.entity_target_not_found',
      );
    });

    test('a target type whose feature is not present is rejected', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      // `habit` is a recognized target type but its owner table is not
      // registered yet (habits land in a later wave). Goals, roadmaps, and
      // Learning Resources are registered from Wave 5 (R-NOTE-002).
      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.habit,
        'habit-1',
        seed: 'x',
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'note.entity_target_type_unavailable',
      );
    });

    test('an unrecognized target type is rejected', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        'gizmo',
        'x-1',
        seed: 'x',
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'note.entity_target_type_unknown',
      );
    });

    test('linking from a trashed note is rejected', () async {
      final String note = await h.createNote(title: 'Design', seed: 'n');
      final String task = await h.insertRawTask(id: 'task-1');
      await h.softDelete(note);

      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.task,
        task,
        seed: 'x',
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'note.not_found',
      );
    });
  });
}
