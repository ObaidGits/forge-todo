import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';

/// A raw (still-encrypted) draft journal row (R-NOTE-005).
final class StoredDraft {
  const StoredDraft({
    required this.noteId,
    required this.baseRevision,
    required this.encryptedBody,
    required this.recoveryStatus,
    required this.updatedAtUtc,
  });

  final String noteId;
  final int baseRevision;
  final String encryptedBody;
  final String recoveryStatus;
  final int updatedAtUtc;
}

/// Transaction-scoped access to the encrypted draft journal (`note_drafts`,
/// R-NOTE-005). It stores the ciphertext only; encryption/decryption is the
/// journal service's concern.
final class NoteDraftWriteRepository {
  NoteDraftWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  Future<StoredDraft?> find(String profileId, String noteId) async {
    scope.ensureActive();
    final NoteDraftRow? row =
        await (db.select(db.noteDrafts)..where(
              (NoteDrafts t) =>
                  t.profileId.equals(profileId) & t.noteId.equals(noteId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return StoredDraft(
      noteId: row.noteId,
      baseRevision: row.baseRevision,
      encryptedBody: row.encryptedBody,
      recoveryStatus: row.recoveryStatus,
      updatedAtUtc: row.updatedAtUtc,
    );
  }

  /// Upserts the current draft for a note. One current draft per note.
  Future<void> upsert({
    required String profileId,
    required String noteId,
    required int baseRevision,
    required String encryptedBody,
    required String recoveryStatus,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT INTO note_drafts '
      '(profile_id, note_id, base_revision, encrypted_body, recovery_status, '
      'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id, note_id) DO UPDATE SET '
      'base_revision = excluded.base_revision, '
      'encrypted_body = excluded.encrypted_body, '
      'recovery_status = excluded.recovery_status, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        profileId,
        noteId,
        baseRevision,
        encryptedBody,
        recoveryStatus,
        nowUtc,
        nowUtc,
      ],
    );
  }

  /// Removes the draft for a note (successful save or explicit discard,
  /// R-NOTE-005). Idempotent.
  Future<void> remove({
    required String profileId,
    required String noteId,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'DELETE FROM note_drafts WHERE profile_id = ? AND note_id = ?',
      <Object?>[profileId, noteId],
    );
  }

  /// Every draft awaiting recovery for [profileId] (offered on next open).
  Future<List<StoredDraft>> awaitingRecovery(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT note_id, base_revision, encrypted_body, recovery_status, "
          "updated_at_utc FROM note_drafts WHERE profile_id = ? "
          "AND recovery_status = 'awaiting_recovery' ORDER BY updated_at_utc",
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows
        .map(
          (QueryRow r) => StoredDraft(
            noteId: r.data['note_id'] as String,
            baseRevision: r.data['base_revision'] as int,
            encryptedBody: r.data['encrypted_body'] as String,
            recoveryStatus: r.data['recovery_status'] as String,
            updatedAtUtc: r.data['updated_at_utc'] as int,
          ),
        )
        .toList(growable: false);
  }
}
