import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/security/secure_storage_key_vault.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/secure_key_store.dart';

import '../../../helpers/fake_secure_key_store.dart';

/// A deterministic, non-secure RNG so provisioned keys are reproducible in
/// tests. NEVER used in production (the vault defaults to [Random.secure]).
final class _SeededRandom implements Random {
  _SeededRandom(this._delegate);
  final Random _delegate;
  @override
  int nextInt(int max) => _delegate.nextInt(max);
  @override
  bool nextBool() => _delegate.nextBool();
  @override
  double nextDouble() => _delegate.nextDouble();
}

void main() {
  const String keyName = SecureStorageKeyVault.defaultKeyName;

  SecureStorageKeyVault buildVault(
    FakeSecureKeyStore store, {
    required bool ciphertextExists,
  }) {
    return SecureStorageKeyVault(
      store: store,
      ciphertextExists: () => ciphertextExists,
      random: _SeededRandom(Random(1234)),
    );
  }

  group('provably-fresh install', () {
    test('provisions, stores, and releases a 32-byte key', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore();
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: false,
      );

      await vault.ensureProvisioned();

      expect(vault.state, KeyVaultState.available);
      expect(
        store.contains(keyName),
        isTrue,
        reason: 'a fresh key must be persisted to secure storage',
      );
      // Stored as base64 of exactly 32 bytes.
      final Uint8List storedBytes = base64Decode(store.valueFor(keyName)!);
      expect(storedBytes, hasLength(32));

      final KeyLease lease = await vault.release();
      final Uint8List released = lease.copyBytes();
      expect(released, hasLength(32));
      expect(released, equals(storedBytes));
      await lease.dispose();
    });

    test(
      'is idempotent: a second ensureProvisioned keeps the same key',
      () async {
        final FakeSecureKeyStore store = FakeSecureKeyStore();
        final SecureStorageKeyVault vault = buildVault(
          store,
          ciphertextExists: false,
        );

        await vault.ensureProvisioned();
        final String first = store.valueFor(keyName)!;
        final int writesAfterFirst = store.writeCount;

        await vault.ensureProvisioned();
        expect(
          store.valueFor(keyName),
          first,
          reason: 'existing key must not be overwritten',
        );
        expect(
          store.writeCount,
          writesAfterFirst,
          reason: 'no second write when a key already exists',
        );
      },
    );
  });

  group('R-SEC-001: existing ciphertext + missing key', () {
    test('ensureProvisioned never mints a replacement key', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore();
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: true,
      );

      await vault.ensureProvisioned();

      expect(vault.state, KeyVaultState.recoveryRequired);
      expect(
        store.contains(keyName),
        isFalse,
        reason: 'no key may be written over existing ciphertext',
      );
      expect(store.writeCount, 0);
    });

    test(
      'release throws KeyReleaseUnavailable(recoveryRequired), no mint',
      () async {
        final FakeSecureKeyStore store = FakeSecureKeyStore();
        final SecureStorageKeyVault vault = buildVault(
          store,
          ciphertextExists: true,
        );

        await vault.ensureProvisioned();

        await expectLater(
          vault.release(),
          throwsA(
            isA<KeyReleaseUnavailable>().having(
              (KeyReleaseUnavailable e) => e.state,
              'state',
              KeyVaultState.recoveryRequired,
            ),
          ),
        );
        expect(store.writeCount, 0, reason: 'release must never mint a key');
        expect(store.contains(keyName), isFalse);
      },
    );
  });

  group('release round-trip', () {
    test('returns the exact stored key bytes', () async {
      final Uint8List seededKey = Uint8List.fromList(
        List<int>.generate(32, (int i) => (i * 7 + 3) & 0xff),
      );
      final FakeSecureKeyStore store = FakeSecureKeyStore(
        seed: <String, String>{keyName: base64Encode(seededKey)},
      );
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: true,
      );

      final KeyLease lease = await vault.release();
      expect(lease.copyBytes(), equals(seededKey));
      expect(vault.state, KeyVaultState.available);
      await lease.dispose();
      // No key was written; the pre-seeded key is untouched.
      expect(store.writeCount, 0);
    });
  });

  group('lease zeroization', () {
    test('dispose zeroizes and blocks further reads', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore();
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: false,
      );
      await vault.ensureProvisioned();

      final KeyLease lease = await vault.release();
      final Uint8List firstCopy = lease.copyBytes();
      expect(
        firstCopy.any((int b) => b != 0),
        isTrue,
        reason: 'a real key is not all-zero',
      );

      expect(lease.isDisposed, isFalse);
      await lease.dispose();
      expect(lease.isDisposed, isTrue);
      expect(lease.copyBytes, throwsStateError);

      // A fresh release still yields the original key: the lease only zeroizes
      // its own defensive copy, not the stored material.
      final KeyLease again = await vault.release();
      expect(again.copyBytes(), equals(firstCopy));
      await again.dispose();
    });
  });

  group('secret service unavailable', () {
    test('ensureProvisioned surfaces SecureKeyStoreUnavailable', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore(available: false);
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: false,
      );

      await expectLater(
        vault.ensureProvisioned(),
        throwsA(isA<SecureKeyStoreUnavailable>()),
      );
    });

    test(
      'release over existing ciphertext fails closed to recoveryRequired',
      () async {
        final FakeSecureKeyStore store = FakeSecureKeyStore(available: false);
        final SecureStorageKeyVault vault = buildVault(
          store,
          ciphertextExists: true,
        );

        await expectLater(
          vault.release(),
          throwsA(
            isA<KeyReleaseUnavailable>().having(
              (KeyReleaseUnavailable e) => e.state,
              'state',
              KeyVaultState.recoveryRequired,
            ),
          ),
        );
      },
    );
  });

  group('corrupt stored key', () {
    test('wrong length => recoveryRequired, no mint', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore(
        seed: <String, String>{
          keyName: base64Encode(Uint8List(16)), // 128-bit, too short
        },
      );
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: true,
      );

      await expectLater(
        vault.release(),
        throwsA(
          isA<KeyReleaseUnavailable>().having(
            (KeyReleaseUnavailable e) => e.state,
            'state',
            KeyVaultState.recoveryRequired,
          ),
        ),
      );
      expect(store.writeCount, 0);
    });

    test('malformed base64 => recoveryRequired', () async {
      final FakeSecureKeyStore store = FakeSecureKeyStore(
        seed: <String, String>{keyName: 'not*valid*base64!!'},
      );
      final SecureStorageKeyVault vault = buildVault(
        store,
        ciphertextExists: true,
      );

      await expectLater(vault.release(), throwsA(isA<KeyReleaseUnavailable>()));
      expect(store.writeCount, 0);
    });
  });
}
