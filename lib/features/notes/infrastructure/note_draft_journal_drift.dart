import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/application/note_draft_cipher.dart';
import 'package:forge/features/notes/application/note_draft_journal.dart';
import 'package:forge/features/notes/domain/note_draft.dart';
import 'package:forge/features/notes/infrastructure/note_draft_repository.dart';

/// Drift-backed [NoteDraftJournal] (R-NOTE-005).
///
/// Draft rows are local-only (never replicated), so the journal writes them
/// through a plain transaction rather than the sync-eligible command bus: there
/// is no receipt, outbox, or journal-of-commands overhead for high-frequency
/// autosave. The draft body is encrypted with the synchronous [NoteDraftCipher]
/// before it touches the database, so nothing legible is persisted and OS
/// restoration data carries no note content.
final class DriftNoteDraftJournal implements NoteDraftJournal {
  DriftNoteDraftJournal({
    required this.unitOfWork,
    required this.cipher,
    required this.clock,
  });

  final UnitOfWork unitOfWork;
  final NoteDraftCipher cipher;
  final Clock clock;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<void> save({
    required ProfileId profileId,
    required NoteId noteId,
    required int baseRevision,
    required String body,
    bool markAwaitingRecovery = false,
  }) async {
    final String sealed = cipher.seal(body);
    final DraftRecoveryStatus status = markAwaitingRecovery
        ? DraftRecoveryStatus.awaitingRecovery
        : DraftRecoveryStatus.active;
    final int now = _now;
    await unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories.resolve<NoteDraftWriteRepository>().upsert(
        profileId: profileId.value,
        noteId: noteId.value,
        baseRevision: baseRevision,
        encryptedBody: sealed,
        recoveryStatus: status.wire,
        nowUtc: now,
      );
    });
  }

  @override
  Future<void> discard({
    required ProfileId profileId,
    required NoteId noteId,
  }) async {
    await unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories.resolve<NoteDraftWriteRepository>().remove(
        profileId: profileId.value,
        noteId: noteId.value,
      );
    });
  }

  @override
  Future<NoteDraft?> load({
    required ProfileId profileId,
    required NoteId noteId,
  }) async {
    return unitOfWork.transaction<NoteDraft?>((
      TransactionSession session,
    ) async {
      final StoredDraft? stored = await session.repositories
          .resolve<NoteDraftWriteRepository>()
          .find(profileId.value, noteId.value);
      if (stored == null) {
        return null;
      }
      return _decrypt(stored);
    });
  }

  @override
  Future<List<NoteDraft>> recoverable(ProfileId profileId) async {
    return unitOfWork.transaction<List<NoteDraft>>((
      TransactionSession session,
    ) async {
      final List<StoredDraft> rows = await session.repositories
          .resolve<NoteDraftWriteRepository>()
          .awaitingRecovery(profileId.value);
      return rows.map(_decrypt).toList(growable: false);
    });
  }

  NoteDraft _decrypt(StoredDraft stored) => NoteDraft(
    noteId: NoteId(stored.noteId),
    baseRevision: stored.baseRevision,
    body: cipher.open(stored.encryptedBody),
    updatedAtUtc: stored.updatedAtUtc,
    recoveryStatus: DraftRecoveryStatus.fromWire(stored.recoveryStatus),
  );
}
