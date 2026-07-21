import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';

/// Hard storage bounds enforced before an attachment is published
/// (R-NOTE-006). Bounds are checked against the *staged* byte count and the
/// live per-profile totals so a partially written or oversized import can never
/// be published.
final class AttachmentQuota {
  const AttachmentQuota({
    required this.maxFileBytes,
    required this.maxProfileBytes,
    required this.maxFileCount,
  }) : assert(maxFileBytes > 0, 'maxFileBytes must be positive'),
       assert(maxProfileBytes > 0, 'maxProfileBytes must be positive'),
       assert(maxFileCount > 0, 'maxFileCount must be positive');

  /// Planning defaults for V1 local attachments: 25 MiB per file, 1 GiB per
  /// profile, 10,000 files. These are configurable at the composition root.
  static const AttachmentQuota defaults = AttachmentQuota(
    maxFileBytes: 25 * 1024 * 1024,
    maxProfileBytes: 1024 * 1024 * 1024,
    maxFileCount: 10000,
  );

  final int maxFileBytes;
  final int maxProfileBytes;
  final int maxFileCount;

  /// Returns the rejection reason for publishing a [fileBytes]-byte attachment
  /// given the current published [profileBytes]/[profileCount], or null when it
  /// fits. Empty files are rejected up front.
  AttachmentRejectionReason? check({
    required int fileBytes,
    required int profileBytes,
    required int profileCount,
  }) {
    if (fileBytes <= 0) {
      return AttachmentRejectionReason.emptyFile;
    }
    if (fileBytes > maxFileBytes) {
      return AttachmentRejectionReason.perFileTooLarge;
    }
    if (profileCount + 1 > maxFileCount) {
      return AttachmentRejectionReason.countQuotaExceeded;
    }
    // Guard against overflow before comparing against the profile ceiling.
    if (profileBytes > maxProfileBytes - fileBytes) {
      return AttachmentRejectionReason.profileQuotaExceeded;
    }
    return null;
  }

  /// Throws [AttachmentRejected] when the attachment does not fit.
  void enforce({
    required int fileBytes,
    required int profileBytes,
    required int profileCount,
  }) {
    final AttachmentRejectionReason? reason = check(
      fileBytes: fileBytes,
      profileBytes: profileBytes,
      profileCount: profileCount,
    );
    if (reason != null) {
      throw AttachmentRejected(reason);
    }
  }
}
