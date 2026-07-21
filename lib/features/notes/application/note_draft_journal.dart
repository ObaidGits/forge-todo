import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note_draft.dart';

/// The encrypted durable draft journal (R-NOTE-005).
///
/// Autosave debounces and flushes to this journal on navigation/background. The
/// journal stores the note id, the exact base revision, the encrypted draft
/// body, the update time, and the recovery status before editor memory may be
/// discarded. A successful save or explicit discard removes the entry. Because
/// the entry is encrypted and local-only, OS restoration data can safely carry
/// only the note id and never any content.
abstract interface class NoteDraftJournal {
  /// Persists (upserts) the current draft for [noteId], encrypting [body].
  ///
  /// [markAwaitingRecovery] is set true just before editor memory is discarded
  /// (e.g. on background), marking the entry as the authoritative unsaved copy
  /// to offer on the next open.
  Future<void> save({
    required ProfileId profileId,
    required NoteId noteId,
    required int baseRevision,
    required String body,
    bool markAwaitingRecovery = false,
  });

  /// Explicitly discards the draft for [noteId] (R-NOTE-005). Idempotent.
  Future<void> discard({required ProfileId profileId, required NoteId noteId});

  /// Loads and decrypts the current draft for [noteId], or null when none.
  Future<NoteDraft?> load({
    required ProfileId profileId,
    required NoteId noteId,
  });

  /// Every draft awaiting recovery for [profileId], decrypted, offered on the
  /// next open.
  Future<List<NoteDraft>> recoverable(ProfileId profileId);
}
