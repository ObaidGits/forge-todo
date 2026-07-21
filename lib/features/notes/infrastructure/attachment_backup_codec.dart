import 'dart:typed_data';

import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';

/// Rewraps managed-attachment keys for the Forge backup container (FBC1) and
/// back on restore (R-BACKUP-001, R-BACKUP-002, R-SEC-002).
///
/// Attachment content is encrypted at rest under its per-file DEK, and the DEK
/// is wrapped under the device KEK. The device KEK is never exported. For
/// backup, each attachment's DEK is *rewrapped* under an independent
/// backup-derived key so the portable archive carries only backup-wrapped keys
/// plus the DEK-encrypted content; on restore the DEK is rewrapped under the
/// (possibly new) device KEK. Because the content ciphertext is unchanged, this
/// is the efficient "rewrap" variant; stream re-encryption would instead
/// decrypt-then-reencrypt content under the backup key. Either way the exported
/// archive never contains the device KEK or a plaintext DEK.
final class AttachmentBackupCodec {
  const AttachmentBackupCodec(this.crypto);

  final AttachmentCrypto crypto;

  /// Rewraps [wrappedDek] (wrapped under the device [kek]) to a backup envelope
  /// wrapped under [backupKey]. The transient DEK is wiped.
  String rewrapForBackup({
    required String wrappedDek,
    required List<int> kek,
    required List<int> backupKey,
  }) {
    final Uint8List dek = crypto.unwrapDek(wrappedDek: wrappedDek, kek: kek);
    try {
      return crypto.wrapDek(dek: dek, kek: backupKey);
    } finally {
      crypto.wipe(dek);
    }
  }

  /// Rewraps a backup envelope [backupWrappedDek] (wrapped under [backupKey])
  /// back under the device [kek] on restore. The transient DEK is wiped.
  String rewrapOnRestore({
    required String backupWrappedDek,
    required List<int> backupKey,
    required List<int> kek,
  }) {
    final Uint8List dek = crypto.unwrapDek(
      wrappedDek: backupWrappedDek,
      kek: backupKey,
    );
    try {
      return crypto.wrapDek(dek: dek, kek: kek);
    } finally {
      crypto.wipe(dek);
    }
  }
}
