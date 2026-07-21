/// Publication/soft-deletion state of a managed attachment.
enum AttachmentState {
  /// The encrypted file is published, hash-pinned, and readable.
  published,

  /// The metadata is retained for the durable deletion journal to reconcile
  /// file cleanup; the file is (or will be) removed and never resurrects.
  deleted,
}

extension AttachmentStateWire on AttachmentState {
  String get wire => switch (this) {
    AttachmentState.published => 'published',
    AttachmentState.deleted => 'deleted',
  };

  static AttachmentState fromWire(String value) => switch (value) {
    'published' => AttachmentState.published,
    'deleted' => AttachmentState.deleted,
    _ => throw ArgumentError.value(value, 'value', 'Unknown attachment state'),
  };
}

/// Immutable metadata for one published managed attachment (R-NOTE-006).
///
/// The encrypted content lives outside SQLite under [pathToken]; this record
/// holds only the metadata needed to open, verify, quota-account, and back up
/// the file. The per-file key is [wrappedDek] — the random DEK wrapped under the
/// device KEK — and is never stored in the clear (R-SEC-002).
final class Attachment {
  const Attachment({
    required this.id,
    required this.profileId,
    required this.noteId,
    required this.displayName,
    required this.declaredMime,
    required this.detectedMime,
    required this.byteSize,
    required this.contentHash,
    required this.wrappedDek,
    required this.cipherVersion,
    required this.pathToken,
    required this.state,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.deletedAtUtc,
  });

  final String id;
  final String profileId;
  final String noteId;
  final String displayName;
  final String declaredMime;
  final String detectedMime;
  final int byteSize;
  final String contentHash;
  final String wrappedDek;
  final String cipherVersion;
  final String pathToken;
  final AttachmentState state;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;
}
