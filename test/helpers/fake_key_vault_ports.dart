import 'package:forge/core/security/key_vault_ports.dart';

/// Deterministic in-memory port fakes for exercising the production
/// [KeyVaultMachine] without native secure-storage, biometric, or KDF plugins.
///
/// These fakes make transitions observable; their string envelopes are labels,
/// not cryptographic outputs. They deliberately never derive plaintext keys.

/// In-memory [VaultStoragePort].
final class InMemoryVaultStorage implements VaultStoragePort {
  @override
  VaultDatabaseMetadata? database;

  @override
  VaultSlot? activeSlot;

  @override
  RotationJournal? rotation;

  @override
  bool deletionMarker = false;

  final Map<VaultSlot, SecureMaterial> _slots = <VaultSlot, SecureMaterial>{};

  @override
  Map<VaultSlot, SecureMaterial> get slots => _slots;

  @override
  void writeSlot(VaultSlot slot, SecureMaterial material) {
    _slots[slot] = material;
  }

  @override
  void removeSlot(VaultSlot slot) {
    _slots.remove(slot);
  }

  @override
  void clearAll() {
    database = null;
    activeSlot = null;
    rotation = null;
    deletionMarker = false;
    _slots.clear();
  }
}

/// Deterministic key source. Distinct handles per call so identity is tracked.
final class FakeRandomKeyPort implements RandomKeyPort {
  int generateCalls = 0;

  @override
  SecureKey generateProfileKey() {
    generateCalls += 1;
    // 32 distinct-but-deterministic bytes seeded by the call counter.
    return SecureKey(
      List<int>.generate(32, (int i) => (generateCalls * 31 + i) & 0xff),
    );
  }
}

final class FakeVaultIdentifierPort implements VaultIdentifierPort {
  int _vault = 0;
  int _key = 0;

  @override
  String nextVaultId() => 'vault-${++_vault}';

  @override
  String nextKeyId() => 'key-${++_key}';
}

/// Deterministic authenticator. Its tags are labels, not real AEAD outputs.
final class FakeMetadataAuthenticator implements MetadataAuthenticatorPort {
  @override
  AuthenticatedBindings authenticate({
    required SecureKey key,
    required String vaultId,
    required String databaseId,
    required String keyId,
    required int generation,
  }) {
    final int fingerprint = key.copyBytes().fold<int>(
      0,
      (int acc, int b) => (acc * 33 + b) & 0x7fffffff,
    );
    final String context = '$vaultId:$databaseId:$keyId:$generation';
    return AuthenticatedBindings(
      sentinelTag: 'sentinel:$context:$fingerprint',
      keyFingerprint: 'fp:$fingerprint',
    );
  }
}

final class _WrappedEntry {
  const _WrappedEntry(this.key, this.credential, this.bindings);
  final SecureKey key;
  final String credential;
  final AuthenticatedBindings bindings;
}

/// Fake Argon2id passphrase wrapping. Records the parameters used so tests can
/// assert versioned-parameter binding without real KDF work.
final class FakePassphraseWrapping implements PassphraseWrappingPort {
  final Map<String, _WrappedEntry> _entries = <String, _WrappedEntry>{};
  final Map<String, Argon2idParameters> _params =
      <String, Argon2idParameters>{};
  int _counter = 0;

  /// When set, every unwrap reports permanent invalidation.
  bool invalidated = false;

  @override
  String wrap({
    required SecureKey key,
    required String passphrase,
    required Argon2idParameters parameters,
    required AuthenticatedBindings bindings,
  }) {
    final String token = 'pin-envelope-${++_counter}';
    // Snapshot the bytes: the machine zeroizes the live key on lock.
    _entries[token] = _WrappedEntry(
      SecureKey(key.copyBytes()),
      passphrase,
      bindings,
    );
    _params[token] = parameters;
    return token;
  }

  @override
  UnwrapOutcome unwrap({
    required String wrappedKey,
    required String passphrase,
    required Argon2idParameters parameters,
    required AuthenticatedBindings expectedBindings,
  }) {
    if (invalidated) {
      return const UnwrapCredentialInvalidated();
    }
    final _WrappedEntry? entry = _entries[wrappedKey];
    final Argon2idParameters? stored = _params[wrappedKey];
    if (entry == null ||
        stored == null ||
        !stored.sameAs(parameters) ||
        entry.credential != passphrase ||
        !entry.bindings.sameAs(expectedBindings)) {
      return const UnwrapInvalidCredential();
    }
    return UnwrapSucceeded(SecureKey(entry.key.copyBytes()));
  }
}

/// Fake biometric-gated wrapping. [nextOutcome] injects one release result.
final class FakeBiometricWrapping implements BiometricWrappingPort {
  final Map<String, _WrappedEntry> _entries = <String, _WrappedEntry>{};
  int _counter = 0;
  ReleaseOutcome nextOutcome = ReleaseOutcome.success;

  @override
  String enroll({
    required SecureKey key,
    required AuthenticatedBindings bindings,
  }) {
    final String token = 'biometric-envelope-${++_counter}';
    _entries[token] = _WrappedEntry(SecureKey(key.copyBytes()), '', bindings);
    return token;
  }

  @override
  UnwrapOutcome release({
    required String wrappedKey,
    required AuthenticatedBindings expectedBindings,
  }) {
    final ReleaseOutcome outcome = nextOutcome;
    nextOutcome = ReleaseOutcome.success;
    switch (outcome) {
      case ReleaseOutcome.invalidated:
        return const UnwrapCredentialInvalidated();
      case ReleaseOutcome.unavailable:
      case ReleaseOutcome.cancelled:
        return const UnwrapUnavailable();
      case ReleaseOutcome.success:
        final _WrappedEntry? entry = _entries[wrappedKey];
        if (entry == null || !entry.bindings.sameAs(expectedBindings)) {
          return const UnwrapCredentialInvalidated();
        }
        return UnwrapSucceeded(SecureKey(entry.key.copyBytes()));
    }
  }
}

/// Fake device secure store that can release without user presence.
final class FakeDeviceSecureStore implements DeviceSecureStorePort {
  final Map<String, _WrappedEntry> _entries = <String, _WrappedEntry>{};
  int _counter = 0;
  bool invalidated = false;
  bool unavailable = false;

  @override
  String wrap({
    required SecureKey key,
    required AuthenticatedBindings bindings,
  }) {
    final String token = 'device-envelope-${++_counter}';
    _entries[token] = _WrappedEntry(SecureKey(key.copyBytes()), '', bindings);
    return token;
  }

  @override
  UnwrapOutcome release({
    required String wrappedKey,
    required AuthenticatedBindings expectedBindings,
  }) {
    if (invalidated) {
      return const UnwrapCredentialInvalidated();
    }
    if (unavailable) {
      return const UnwrapUnavailable();
    }
    final _WrappedEntry? entry = _entries[wrappedKey];
    if (entry == null || !entry.bindings.sameAs(expectedBindings)) {
      return const UnwrapCredentialInvalidated();
    }
    return UnwrapSucceeded(SecureKey(entry.key.copyBytes()));
  }
}
