import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/domain/note_draft.dart';

import 'note_test_support.dart';

/// Real Drift-backed encrypted draft-journal tests (R-NOTE-005).
///
/// The journal stores the note id, exact base revision, encrypted draft body,
/// update time and recovery status; a successful save or explicit discard
/// removes it; and the persisted body is never legible plaintext.
///
/// **Validates: Requirements R-NOTE-005**
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  test('a saved draft is stored encrypted and round-trips on load', () async {
    final String id = await h.createNote(title: 'Journal', body: 'saved v1');
    final NoteId noteId = NoteId(id);

    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'unsaved secret edit',
    );

    // The raw stored body is NOT the plaintext (encrypted at rest).
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT base_revision, encrypted_body, recovery_status '
      'FROM note_drafts WHERE note_id = ?',
      <Object?>[id],
    );
    expect(row!['base_revision'], 1);
    expect(row['encrypted_body'], isNot(contains('unsaved secret edit')));
    expect(row['recovery_status'], 'active');

    // Decryption via the journal returns the exact draft.
    final NoteDraft? draft = await h.journal.load(
      profileId: h.profileId,
      noteId: noteId,
    );
    expect(draft!.body, 'unsaved secret edit');
    expect(draft.baseRevision, 1);
  });

  test('marking awaiting-recovery surfaces the draft in recoverable', () async {
    final String id = await h.createNote(title: 'Recover', body: 'x');
    final NoteId noteId = NoteId(id);
    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'in-flight edit',
      markAwaitingRecovery: true,
    );

    final List<NoteDraft> recoverable = await h.journal.recoverable(
      h.profileId,
    );
    expect(recoverable, hasLength(1));
    expect(recoverable.single.noteId.value, id);
    expect(recoverable.single.body, 'in-flight edit');
    expect(
      recoverable.single.recoveryStatus,
      DraftRecoveryStatus.awaitingRecovery,
    );
  });

  test('explicit discard removes the draft (R-NOTE-005)', () async {
    final String id = await h.createNote();
    final NoteId noteId = NoteId(id);
    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'to discard',
    );
    await h.journal.discard(profileId: h.profileId, noteId: noteId);
    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 0);
    expect(
      await h.journal.load(profileId: h.profileId, noteId: noteId),
      isNull,
    );
  });

  test('a successful note save removes the pending draft', () async {
    final String id = await h.createNote(
      title: 'Save clears draft',
      body: 'v1',
    );
    final NoteId noteId = NoteId(id);
    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'v2 in progress',
    );
    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 1);

    // Committing the edit through the note command service clears the draft in
    // the same transaction as the save.
    await h.notes.update(
      commandId: h.nextCommandId('save'),
      profileId: h.profileId,
      noteId: noteId,
      input: const UpdateNoteInput(body: 'v2 in progress'),
    );
    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 0);
  });

  test('saving twice keeps a single current draft per note', () async {
    final String id = await h.createNote();
    final NoteId noteId = NoteId(id);
    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'first',
    );
    await h.journal.save(
      profileId: h.profileId,
      noteId: noteId,
      baseRevision: 1,
      body: 'second',
    );
    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 1);
    final NoteDraft? draft = await h.journal.load(
      profileId: h.profileId,
      noteId: noteId,
    );
    expect(draft!.body, 'second');
  });
}
