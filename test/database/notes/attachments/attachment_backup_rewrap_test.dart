import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';
import 'package:forge/features/notes/infrastructure/attachment_backup_codec.dart';

import '../../../helpers/fake_attachment_crypto.dart';

/// Backup rewrap / stream re-encryption and key portability for managed
/// attachments (task 10.3).
///
/// **Validates: Requirements R-BACKUP-001, R-BACKUP-002, R-SEC-002**
void main() {
  late FakeAttachmentCrypto crypto;
  late AttachmentBackupCodec codec;

  final List<int> deviceKek = <int>[1, 2, 3, 4, 5, 6, 7, 8];
  final List<int> backupKey = <int>[9, 9, 9, 9, 8, 8, 8, 8];
  final List<int> restoreKek = <int>[7, 7, 7, 7, 6, 6, 6, 6];

  setUp(() {
    crypto = FakeAttachmentCrypto();
    codec = AttachmentBackupCodec(crypto);
  });

  test(
    'rewraps a DEK under the backup key and back on restore (roundtrip)',
    () async {
      final List<int> plaintext = <int>[10, 20, 30, 40, 50, 60];
      final Uint8List dek = crypto.newDek();
      final Uint8List ciphertext = crypto.sealContent(
        plaintext: plaintext,
        dek: dek,
      );
      final String deviceWrapped = crypto.wrapDek(dek: dek, kek: deviceKek);

      // Export: rewrap the device-wrapped DEK under the independent backup key.
      final String backupWrapped = codec.rewrapForBackup(
        wrappedDek: deviceWrapped,
        kek: deviceKek,
        backupKey: backupKey,
      );
      expect(backupWrapped, isNot(deviceWrapped));

      // Restore onto a *different* device KEK.
      final String restoredWrapped = codec.rewrapOnRestore(
        backupWrappedDek: backupWrapped,
        backupKey: backupKey,
        kek: restoreKek,
      );

      // The content is portable: unwrap under the new KEK and decrypt.
      final Uint8List restoredDek = crypto.unwrapDek(
        wrappedDek: restoredWrapped,
        kek: restoreKek,
      );
      final Uint8List recovered = crypto.openContent(
        ciphertext: ciphertext,
        dek: restoredDek,
      );
      expect(recovered, orderedEquals(plaintext));
    },
  );

  test('the backup envelope cannot be unwrapped with the device KEK', () {
    final Uint8List dek = crypto.newDek();
    final String deviceWrapped = crypto.wrapDek(dek: dek, kek: deviceKek);
    final String backupWrapped = codec.rewrapForBackup(
      wrappedDek: deviceWrapped,
      kek: deviceKek,
      backupKey: backupKey,
    );

    // The device KEK never opens a backup-wrapped key: authentication fails.
    expect(
      () => crypto.unwrapDek(wrappedDek: backupWrapped, kek: deviceKek),
      throwsA(isA<AttachmentCryptoAuthError>()),
    );
  });

  test('a wrong device KEK cannot rewrap for backup (key portability)', () {
    final Uint8List dek = crypto.newDek();
    final String deviceWrapped = crypto.wrapDek(dek: dek, kek: deviceKek);

    expect(
      () => codec.rewrapForBackup(
        wrappedDek: deviceWrapped,
        kek: <int>[0, 0, 0, 0, 0, 0, 0, 0],
        backupKey: backupKey,
      ),
      throwsA(isA<AttachmentCryptoAuthError>()),
    );
  });
}
