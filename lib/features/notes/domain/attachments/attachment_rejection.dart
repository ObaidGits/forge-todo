/// Reasons a managed-attachment import is rejected by the security-first
/// staged-write pipeline (R-NOTE-006, R-SEC-002, R-SEC-005).
///
/// Every rejection is fail-closed: the source is never published, staged bytes
/// are cleaned up, and no note is corrupted. These reasons are pure domain
/// values so both the policy checks and the pipeline can share them without
/// depending on any IO or crypto implementation.
enum AttachmentRejectionReason {
  /// The source is not a regular file (symlink, directory, FIFO, socket, or
  /// device). Only regular files are ever imported.
  notRegularFile,

  /// The opened file descriptor no longer matches the file that was checked:
  /// a time-of-check/time-of-use (TOCTOU) replacement between validation and
  /// read. The import is abandoned.
  sourceChangedDuringImport,

  /// The content's magic bytes do not correspond to any accepted type.
  unsupportedType,

  /// A declared MIME/type was supplied but disagrees with the detected magic
  /// bytes.
  declaredTypeMismatch,

  /// The file is empty; empty attachments are not accepted.
  emptyFile,

  /// The file exceeds the per-file byte ceiling.
  perFileTooLarge,

  /// Publishing the file would exceed the per-profile storage quota.
  profileQuotaExceeded,

  /// Publishing the file would exceed the per-profile attachment count quota.
  countQuotaExceeded,

  /// The content hash computed from staged bytes did not match the streamed
  /// content (corruption or tampering during staging).
  hashMismatch,
}

/// Thrown by the pipeline when an import cannot be trusted. Never mutates the
/// live store or leaves published state behind.
final class AttachmentRejected implements Exception {
  const AttachmentRejected(this.reason, [this.detail]);

  final AttachmentRejectionReason reason;
  final String? detail;

  @override
  String toString() =>
      'AttachmentRejected(${reason.name}${detail == null ? '' : ': $detail'})';
}
