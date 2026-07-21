import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Managed attachments schema (data-model.md §3 "Notes and files"; R-NOTE-006,
// R-SEC-002). Additive at schema v11.
// ---------------------------------------------------------------------------
//
// `attachments` is an inherited-area child of a note: every row carries
// `(profile_id, note_id)` and references `notes (profile_id, id)`, inheriting
// its Life Area from the owning note exactly like `note_drafts` (data-model
// §1). It stores metadata only — the encrypted file content lives outside
// SQLite under a generated path token and is hash-pinned (R-NOTE-006).
//
// Each attachment is encrypted at rest with its own random data-encryption key
// (DEK). The DEK is never stored in the clear: `wrapped_dek` holds the DEK
// wrapped under the device profile key-encryption key (KEK) released by the
// KeyVault, so a stolen database file is useless without the device key
// (R-SEC-002). `cipher_version` versions the content/DEK cipher so a future
// provider migration can rewrap without ambiguity.
//
// A row exists only once the staged file has been fsynced and atomically
// published (the staged-write pipeline journals the operation in `file_journal`
// first). `state` is the publication/soft-deletion state; a `deleted` row keeps
// its metadata for the durable deletion journal to reconcile file cleanup and
// never resurrects a purged file.

/// Managed encrypted attachments (R-NOTE-006, R-SEC-002).
@DataClassName('AttachmentRow')
@TableIndex(name: 'ix_attachments_note', columns: {#profileId, #noteId})
@TableIndex(name: 'ix_attachments_hash', columns: {#profileId, #contentHash})
@TableIndex(name: 'ix_attachments_state', columns: {#profileId, #state})
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();

  /// Owning note. The composite FK inherits profile/area and rejects
  /// cross-profile references at the database boundary (R-GEN-002).
  TextColumn get noteId => text()();

  /// User-facing file name. Never used as a filesystem path.
  TextColumn get displayName => text()();

  /// MIME advertised by the source/extension at import time.
  TextColumn get declaredMime => text()();

  /// MIME detected from the file's magic bytes during staging. The publication
  /// pipeline rejects a mismatch outside the accepted set (R-NOTE-006).
  TextColumn get detectedMime => text()();

  IntColumn get byteSize => integer()();

  /// SHA-256 (lowercase hex) of the plaintext content, pinned at publication
  /// and verified by backup (R-NOTE-006, R-BACKUP-003).
  TextColumn get contentHash => text()();

  /// The per-file DEK wrapped under the device KEK. Opaque; never plaintext.
  TextColumn get wrappedDek => text()();

  /// Versioned content/DEK cipher identifier.
  TextColumn get cipherVersion => text()();

  /// Generated internal path token for the encrypted file. Never a
  /// user-supplied path; traversal/absolute paths are never accepted.
  TextColumn get pathToken => text()();

  /// Publication/soft-deletion state.
  TextColumn get state =>
      text().withDefault(const Constant<String>('published'))();

  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, path_token)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, note_id) REFERENCES notes (profile_id, id)',
    'CHECK (byte_size >= 0)',
    "CHECK (state IN ('published', 'deleted'))",
    "CHECK ((state = 'deleted') = (deleted_at_utc IS NOT NULL))",
  ];
}
