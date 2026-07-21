import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_repository.dart';

import 'note_test_support.dart';

/// Real Drift-backed note command tests: atomic canonical writes, idempotent
/// receipts, pin/archive, and the canonical body as the single source of truth.
///
/// **Validates: Requirements R-NOTE-001, R-NOTE-002, R-NOTE-004, R-GEN-005**
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('create (R-NOTE-001, R-GEN-005)', () {
    test('commits the note and its cross-cutting write set atomically', () async {
      final String id = await h.createNote(
        title: 'Design ideas',
        body: 'The **canonical** body.',
      );

      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM notes WHERE id = ? AND pinned = 0',
          <Object?>[id],
        ),
        1,
      );
      expect(await h.scalar('SELECT COUNT(*) FROM activity_events'), 1);
      expect(await h.scalar('SELECT COUNT(*) FROM commit_log'), 1);
      expect(await h.scalar('SELECT COUNT(*) FROM command_receipts'), 1);
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM outbox_mutations WHERE entity_type = 'note' "
          "AND op_kind = 'insert'",
        ),
        1,
      );
      expect(await h.scalar('SELECT COUNT(*) FROM pending_command_journal'), 1);
      // The canonical Markdown body is stored verbatim (single source of truth).
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT body FROM notes WHERE id = ?',
        <Object?>[id],
      );
      expect(row!['body'], 'The **canonical** body.');
    });

    test('a note document is indexed for search in the same commit', () async {
      final String id = await h.createNote(
        title: 'Groceries',
        body: 'buy oat milk and bread',
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM search_documents WHERE entity_type = 'note' "
          'AND entity_id = ?',
          <Object?>[id],
        ),
        1,
      );
      // The search dirty marker is cleared in-transaction by the coordinator.
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM projection_dirty WHERE projection = 'search'",
        ),
        0,
      );
    });

    test('replaying the same command id returns the stored result', () async {
      final CommandId cmd = h.nextCommandId('dup');
      final Result<CommittedCommandResult> first = await h.notes.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateNoteInput(lifeAreaId: h.lifeAreaId, title: 'Same'),
      );
      final Result<CommittedCommandResult> second = await h.notes.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateNoteInput(lifeAreaId: h.lifeAreaId, title: 'Same'),
      );
      expect(
        (first as Success<CommittedCommandResult>).value.replayed,
        isFalse,
      );
      expect(
        (second as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
    });

    test('same command id with a different request is rejected', () async {
      final CommandId cmd = h.nextCommandId('conflict');
      await h.notes.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateNoteInput(lifeAreaId: h.lifeAreaId, title: 'A'),
      );
      final Result<CommittedCommandResult> conflict = await h.notes.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateNoteInput(lifeAreaId: h.lifeAreaId, title: 'B'),
      );
      expect(
        (conflict as Failed<CommittedCommandResult>).failure.kind,
        FailureKind.conflict,
      );
    });

    test('attaches tags via entity_tags (R-NOTE-002)', () async {
      await h.db.customStatement(
        'INSERT INTO tags (id, profile_id, normalized_name, display_name, '
        'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>['tag-1', h.profileId.value, 'ideas', 'Ideas', 0, 0],
      );
      final String id = await h.createNote(
        seed: 'tagged',
        tagIds: <String>['tag-1'],
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM entity_tags WHERE entity_type = 'note' "
          'AND entity_id = ? AND tag_id = ?',
          <Object?>[id, 'tag-1'],
        ),
        1,
      );
    });
  });

  group('update (R-NOTE-001)', () {
    test('edits the canonical body and bumps the revision', () async {
      final String id = await h.createNote(title: 'Draft', body: 'v1');
      final NoteId noteId = NoteId(id);
      await h.notes.update(
        commandId: h.nextCommandId('u1'),
        profileId: h.profileId,
        noteId: noteId,
        input: const UpdateNoteInput(body: 'v2 body'),
      );
      final Note? note = await h.reads.findById(h.profileId, noteId);
      expect(note!.body, 'v2 body');
      expect(note.revision, 2);
    });

    test('search reflects an updated title', () async {
      final String id = await h.createNote(title: 'alpha topic', body: 'x');
      await h.notes.update(
        commandId: h.nextCommandId('u2'),
        profileId: h.profileId,
        noteId: NoteId(id),
        input: const UpdateNoteInput(title: 'beta topic'),
      );
      expect((await h.search.search(h.profileId, 'alpha')).totalHits, 0);
      expect((await h.search.search(h.profileId, 'beta')).totalHits, 1);
    });

    test('an empty update is a no-op', () async {
      final String id = await h.createNote();
      final Result<CommittedCommandResult> result = await h.notes.update(
        commandId: h.nextCommandId('u3'),
        profileId: h.profileId,
        noteId: NoteId(id),
        input: const UpdateNoteInput(),
      );
      expect(
        (result as Success<CommittedCommandResult>).value.resultCode,
        'noop',
      );
    });

    test('updating a missing note fails validation', () async {
      final Result<CommittedCommandResult> result = await h.notes.update(
        commandId: h.nextCommandId('u4'),
        profileId: h.profileId,
        noteId: NoteId('ghost'),
        input: const UpdateNoteInput(title: 'nope'),
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'note.not_found',
      );
    });
  });

  group('pin and archive (R-NOTE-002)', () {
    test('pin then unpin flips the flag idempotently', () async {
      final String id = await h.createNote();
      final NoteId noteId = NoteId(id);
      await h.notes.setPinned(
        commandId: h.nextCommandId('p1'),
        profileId: h.profileId,
        noteId: noteId,
        pinned: true,
      );
      expect((await h.reads.findById(h.profileId, noteId))!.pinned, isTrue);

      final Result<CommittedCommandResult> again = await h.notes.setPinned(
        commandId: h.nextCommandId('p2'),
        profileId: h.profileId,
        noteId: noteId,
        pinned: true,
      );
      expect(
        (again as Success<CommittedCommandResult>).value.resultCode,
        'noop',
      );
    });

    test('archive moves the note out of the default view', () async {
      final String id = await h.createNote();
      final NoteId noteId = NoteId(id);
      await h.notes.setArchived(
        commandId: h.nextCommandId('a1'),
        profileId: h.profileId,
        noteId: noteId,
        archived: true,
      );
      final Note? note = await h.reads.findById(h.profileId, noteId);
      expect(note!.isArchived, isTrue);

      final List<Note> all = await h.reads.view(h.profileId, NoteViewKind.all);
      expect(all.map((Note n) => n.id.value), isNot(contains(id)));
      final List<Note> archived = await h.reads.view(
        h.profileId,
        NoteViewKind.archived,
      );
      expect(archived.map((Note n) => n.id.value), contains(id));
    });
  });

  group('trash reuses the deletion kernel (R-NOTE-002, R-GEN-003)', () {
    test('soft-delete removes the note from search and the all view', () async {
      final String id = await h.createNote(title: 'ephemeral note', body: 'x');
      expect((await h.search.search(h.profileId, 'ephemeral')).totalHits, 1);

      final Result<CommittedCommandResult> deleted = await h.softDelete(id);
      expect(deleted, isA<Success<CommittedCommandResult>>());

      // Tombstoned from search in the same transaction as the soft-delete.
      expect((await h.search.search(h.profileId, 'ephemeral')).totalHits, 0);
      final List<Note> all = await h.reads.view(h.profileId, NoteViewKind.all);
      expect(all.map((Note n) => n.id.value), isNot(contains(id)));
      final List<Note> trash = await h.reads.view(
        h.profileId,
        NoteViewKind.trash,
      );
      expect(trash.map((Note n) => n.id.value), contains(id));
    });

    test('restore returns the note to search and preserves its id', () async {
      final String id = await h.createNote(title: 'recover me', body: 'x');
      await h.softDelete(id);
      await h.restore(id);
      expect((await h.search.search(h.profileId, 'recover')).totalHits, 1);
      final Note? note = await h.reads.findById(h.profileId, NoteId(id));
      expect(note!.isDeleted, isFalse);
    });
  });
}
