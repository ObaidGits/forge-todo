import 'dart:typed_data';

import 'package:forge/features/notes/domain/attachments/attachment.dart';

/// A request to import an external file as a managed attachment of a note
/// (R-NOTE-006).
final class AttachmentImportRequest {
  const AttachmentImportRequest({
    required this.attachmentId,
    required this.profileId,
    required this.noteId,
    required this.sourcePath,
    required this.displayName,
    this.declaredMime = '',
  });

  final String attachmentId;
  final String profileId;
  final String noteId;

  /// Absolute path of the external source. It is opened under TOCTOU-safe
  /// discipline; symlinks and special files are rejected.
  final String sourcePath;

  /// User-facing name, never used as a filesystem path.
  final String displayName;

  /// Optional caller-declared MIME; validated against detected magic bytes.
  final String declaredMime;
}

/// The decrypted content of an attachment plus its metadata, returned by a
/// safe (in-app) open. Used for allowlisted preview.
final class AttachmentReadResult {
  const AttachmentReadResult({
    required this.attachment,
    required this.bytes,
    required this.safeForPreview,
  });

  final Attachment attachment;
  final Uint8List bytes;
  final bool safeForPreview;
}

/// The outcome of a confirmed external open (R-NOTE-006, R-SEC-005). The
/// decrypted file lives at [tempPath] under a least-lived grant and MUST be
/// released via [dispose] once the platform opener no longer needs it.
final class AttachmentExternalOpen {
  const AttachmentExternalOpen(this.attachment, this.tempPath, this._dispose);

  final Attachment attachment;
  final String tempPath;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// Managed-attachment application service (design.md §9 `AttachmentStore`).
///
/// Implementations run the security-first staged-write import pipeline, publish
/// metadata transactionally, journal deletions durably, and open attachments
/// safely. The concrete implementation lives in infrastructure and depends only
/// on the crypto/filesystem ports and the KeyVault, keeping the notes feature
/// free of any cipher/IO dependency.
abstract interface class AttachmentStore {
  /// Imports [request] through the staged-write pipeline and returns the
  /// published [Attachment]. Rejections throw `AttachmentRejected`.
  Future<Attachment> importAttachment(AttachmentImportRequest request);

  /// Decrypts and returns an attachment's content for safe in-app use. The
  /// result flags whether the type is on the preview allowlist.
  Future<AttachmentReadResult> readForPreview({
    required String profileId,
    required String attachmentId,
  });

  /// Materialises a decrypted temp file for a confirmed external open. Requires
  /// [confirmed] to be true (explicit user action, R-SEC-005).
  Future<AttachmentExternalOpen> openExternally({
    required String profileId,
    required String attachmentId,
    required bool confirmed,
  });

  /// Soft-deletes an attachment: marks metadata `deleted`, journals the file
  /// deletion durably, and removes the encrypted file. Idempotent.
  Future<void> deleteAttachment({
    required String profileId,
    required String attachmentId,
  });
}

/// Raised when an external open is attempted without explicit confirmation.
final class AttachmentConfirmationRequired implements Exception {
  const AttachmentConfirmationRequired();

  @override
  String toString() => 'AttachmentConfirmationRequired()';
}

/// Raised when an attachment cannot be found for the active profile.
final class AttachmentNotFound implements Exception {
  const AttachmentNotFound(this.attachmentId);

  final String attachmentId;

  @override
  String toString() => 'AttachmentNotFound($attachmentId)';
}
