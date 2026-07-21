/// Ports, value types, and parameters for the production KeyVault state machine.
///
/// Every platform or cryptographic capability the vault depends on is expressed
/// as a narrow port here so the state machine can be exercised deterministically
/// without native secure-storage, biometric, or KDF plugins. Production wiring
/// supplies platform adapters at the composition root; tests supply in-memory
/// fakes. The state machine itself (see `key_vault_machine.dart`) contains no
/// platform imports and never bypasses these ports.
library;

import 'dart:typed_data';

/// The protection that guards release of the profile key-encryption key.
enum VaultProtection {
  /// Argon2id passphrase/PIN-wrapped fallback (e.g. Linux without a usable
  /// secret service, or an explicit user PIN). Requires user presence.
  pinFallback,

  /// OS biometric-gated release (Android Keystore/BiometricPrompt, iOS
  /// Keychain + Secure Enclave). Requires user presence and can be invalidated
  /// by enrollment changes.
  biometric,

  /// Device-protected secure storage that can release without user presence
  /// (Windows DPAPI/protected storage, Linux Secret Service, Keychain without
  /// biometry). Eligible for headless background release.
  deviceSecureStore,
}

extension VaultProtectionPresence on VaultProtection {
  /// Whether release requires an interactive user-presence check. Only
  /// [VaultProtection.deviceSecureStore] can release headless.
  bool get requiresUserPresence => this != VaultProtection.deviceSecureStore;
}

/// The two rotation slots. Rotation always writes the incoming key to the
/// inactive slot and only ever removes the outgoing slot after the active
/// pointer commits, so a crash always leaves at least one usable slot.
enum VaultSlot { a, b }

extension VaultSlotOther on VaultSlot {
  VaultSlot get other => this == VaultSlot.a ? VaultSlot.b : VaultSlot.a;
}

/// Durable crash points for a two-slot rotation. Persisted in the rotation
/// journal so recovery on the next launch is deterministic.
enum RotationPhase { draft, prepared, databaseCommitted, vaultCommitted }

/// Why the vault fails closed into Recovery Mode. Existing ciphertext with any
/// of these conditions must never mint a replacement key.
enum VaultRecoveryReason {
  secureMaterialMissing,
  orphanedSecureMaterial,
  unsupportedVaultVersion,
  databaseVersionMismatch,
  keyVersionMismatch,
  generationVersionMismatch,
  vaultIdMismatch,
  databaseIdMismatch,
  keyIdMismatch,
  generationMismatch,
  sentinelMismatch,
  fingerprintMismatch,
  protectionUnavailable,
  parametersOutOfPolicy,
  credentialInvalidated,
  rotationMetadataMismatch,
}

/// Why a requested transition was rejected without side effects.
enum VaultRejection {
  invalidTransition,
  plaintextProhibited,
  credentialRequired,
  retryLimitReached,
  deletionTokenMismatch,
}

/// The outcome of a biometric/device release attempt reported by an adapter.
enum ReleaseOutcome { success, unavailable, cancelled, invalidated }

/// A live, zeroizable profile key.
///
/// The bytes are copied out for the minimum window required to configure the
/// cipher; [destroy] zeroizes the backing buffer. The state machine destroys
/// superseded keys during rotation and deletion.
final class SecureKey {
  SecureKey(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Key must not be empty.');
    }
  }

  final Uint8List _bytes;
  bool _destroyed = false;

  bool get isDestroyed => _destroyed;

  int get lengthInBytes => _bytes.length;

  /// A defensive copy of the key bytes. Throws once [destroy] has run.
  Uint8List copyBytes() {
    if (_destroyed) {
      throw StateError('SecureKey has been destroyed.');
    }
    return Uint8List.fromList(_bytes);
  }

  /// Zeroizes the backing buffer. Idempotent.
  void destroy() {
    _bytes.fillRange(0, _bytes.length, 0);
    _destroyed = true;
  }

  @override
  String toString() => 'SecureKey(<redacted>)';
}

/// Versioned, bounded Argon2id parameters for PIN/passphrase key wrapping.
///
/// The default planning parameters mirror the Wave 0 FBC1 evidence
/// (Argon2id v19, 64 MiB, 3 iterations, parallelism 4). Parameters are stored
/// in the wrapped material and validated on every release so a downgraded or
/// out-of-policy envelope fails closed rather than silently accepting weaker
/// work.
final class Argon2idParameters {
  const Argon2idParameters({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required this.saltLength,
    required this.keyLength,
    this.version = 0x13,
  });

  /// Planning defaults for PIN/passphrase wrapping (parameter policy v1).
  static const Argon2idParameters pinV1 = Argon2idParameters(
    memoryKiB: 65536,
    iterations: 3,
    parallelism: 4,
    saltLength: 16,
    keyLength: 32,
  );

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final int saltLength;
  final int keyLength;
  final int version;

  /// Bounded acceptance policy. Values outside these ranges fail closed.
  bool get isWithinPolicy =>
      version == 0x13 &&
      memoryKiB >= 19456 &&
      memoryKiB <= 1048576 &&
      iterations >= 2 &&
      iterations <= 10 &&
      parallelism >= 1 &&
      parallelism <= 4 &&
      saltLength >= 16 &&
      keyLength >= 32;

  bool sameAs(Argon2idParameters other) =>
      version == other.version &&
      memoryKiB == other.memoryKiB &&
      iterations == other.iterations &&
      parallelism == other.parallelism &&
      saltLength == other.saltLength &&
      keyLength == other.keyLength;
}

/// Authenticated bindings that tie a wrapped key to the exact database it
/// unlocks. A restore, copy, or tamper that changes any bound identity yields
/// a mismatch and Recovery Mode rather than a silent key reset.
final class AuthenticatedBindings {
  const AuthenticatedBindings({
    required this.sentinelTag,
    required this.keyFingerprint,
  });

  final String sentinelTag;
  final String keyFingerprint;

  AuthenticatedBindings copyWith({
    String? sentinelTag,
    String? keyFingerprint,
  }) {
    return AuthenticatedBindings(
      sentinelTag: sentinelTag ?? this.sentinelTag,
      keyFingerprint: keyFingerprint ?? this.keyFingerprint,
    );
  }

  bool sameAs(AuthenticatedBindings other) =>
      sentinelTag == other.sentinelTag &&
      keyFingerprint == other.keyFingerprint;
}

/// The authenticated identity the encrypted database records about its key.
/// The vault compares this against the secure material on release.
final class VaultDatabaseMetadata {
  const VaultDatabaseMetadata({
    required this.vaultVersion,
    required this.databaseVersion,
    required this.keyVersion,
    required this.generationVersion,
    required this.vaultId,
    required this.databaseId,
    required this.keyId,
    required this.generation,
    required this.bindings,
  });

  final int vaultVersion;
  final int databaseVersion;
  final int keyVersion;
  final int generationVersion;
  final String vaultId;
  final String databaseId;
  final String keyId;
  final int generation;
  final AuthenticatedBindings bindings;

  VaultDatabaseMetadata copyWith({
    int? vaultVersion,
    int? databaseVersion,
    int? keyVersion,
    int? generationVersion,
    String? vaultId,
    String? databaseId,
    String? keyId,
    int? generation,
    AuthenticatedBindings? bindings,
  }) {
    return VaultDatabaseMetadata(
      vaultVersion: vaultVersion ?? this.vaultVersion,
      databaseVersion: databaseVersion ?? this.databaseVersion,
      keyVersion: keyVersion ?? this.keyVersion,
      generationVersion: generationVersion ?? this.generationVersion,
      vaultId: vaultId ?? this.vaultId,
      databaseId: databaseId ?? this.databaseId,
      keyId: keyId ?? this.keyId,
      generation: generation ?? this.generation,
      bindings: bindings ?? this.bindings,
    );
  }
}

/// The wrapped key envelope persisted in secure storage for one slot.
final class SecureMaterial {
  const SecureMaterial({
    required this.vaultVersion,
    required this.databaseVersion,
    required this.keyVersion,
    required this.generationVersion,
    required this.vaultId,
    required this.databaseId,
    required this.keyId,
    required this.generation,
    required this.bindings,
    required this.protection,
    required this.wrappedKey,
    required this.parameters,
  });

  final int vaultVersion;
  final int databaseVersion;
  final int keyVersion;
  final int generationVersion;
  final String vaultId;
  final String databaseId;
  final String keyId;
  final int generation;
  final AuthenticatedBindings bindings;
  final VaultProtection protection;

  /// Opaque wrapped-key envelope produced by a wrapping port. Never contains
  /// raw key bytes.
  final String wrappedKey;

  /// KDF parameters used by [VaultProtection.pinFallback]; null otherwise.
  final Argon2idParameters? parameters;

  bool get requiresUserPresence => protection.requiresUserPresence;

  VaultDatabaseMetadata get metadata => VaultDatabaseMetadata(
    vaultVersion: vaultVersion,
    databaseVersion: databaseVersion,
    keyVersion: keyVersion,
    generationVersion: generationVersion,
    vaultId: vaultId,
    databaseId: databaseId,
    keyId: keyId,
    generation: generation,
    bindings: bindings,
  );

  SecureMaterial copyWith({
    String? keyId,
    int? generation,
    AuthenticatedBindings? bindings,
    String? wrappedKey,
    Argon2idParameters? parameters,
  }) {
    return SecureMaterial(
      vaultVersion: vaultVersion,
      databaseVersion: databaseVersion,
      keyVersion: keyVersion,
      generationVersion: generationVersion,
      vaultId: vaultId,
      databaseId: databaseId,
      keyId: keyId ?? this.keyId,
      generation: generation ?? this.generation,
      bindings: bindings ?? this.bindings,
      protection: protection,
      wrappedKey: wrappedKey ?? this.wrappedKey,
      parameters: parameters ?? this.parameters,
    );
  }
}

/// The durable rotation journal. Its [phase] is advanced before each
/// irreversible step so recovery can resume deterministically.
final class RotationJournal {
  const RotationJournal({
    required this.oldSlot,
    required this.newSlot,
    required this.phase,
  });

  final VaultSlot oldSlot;
  final VaultSlot newSlot;
  final RotationPhase phase;

  RotationJournal at(RotationPhase next) =>
      RotationJournal(oldSlot: oldSlot, newSlot: newSlot, phase: next);
}

/// The result of attempting to unwrap/release a key from a wrapping port.
sealed class UnwrapOutcome {
  const UnwrapOutcome();
}

final class UnwrapSucceeded extends UnwrapOutcome {
  const UnwrapSucceeded(this.key);
  final SecureKey key;
}

/// A wrong PIN/passphrase. Counts toward the bounded retry limit.
final class UnwrapInvalidCredential extends UnwrapOutcome {
  const UnwrapInvalidCredential();
}

/// The protection was permanently invalidated (e.g. biometric enrollment
/// changed). Fails closed to Recovery Mode.
final class UnwrapCredentialInvalidated extends UnwrapOutcome {
  const UnwrapCredentialInvalidated();
}

/// Release is temporarily unavailable (cancelled prompt, sensor unavailable,
/// locked secret service). Leaves ciphertext untouched.
final class UnwrapUnavailable extends UnwrapOutcome {
  const UnwrapUnavailable();
}

/// Persists vault metadata, slots, active pointer, rotation journal, and the
/// deletion marker. All state the vault needs to survive a restart lives here.
abstract interface class VaultStoragePort {
  VaultDatabaseMetadata? get database;
  VaultSlot? get activeSlot;
  RotationJournal? get rotation;
  bool get deletionMarker;
  Map<VaultSlot, SecureMaterial> get slots;

  set database(VaultDatabaseMetadata? value);
  set activeSlot(VaultSlot? value);
  set rotation(RotationJournal? value);
  set deletionMarker(bool value);

  void writeSlot(VaultSlot slot, SecureMaterial material);
  void removeSlot(VaultSlot slot);
  void clearAll();
}

/// Cryptographically secure random key material.
abstract interface class RandomKeyPort {
  SecureKey generateProfileKey();
}

/// Assigns stable vault/key identifiers.
abstract interface class VaultIdentifierPort {
  String nextVaultId();
  String nextKeyId();
}

/// Authenticates the binding between a key and its database identity. In
/// production this is an AEAD/HMAC over the identity tuple; the result never
/// reveals the key.
abstract interface class MetadataAuthenticatorPort {
  AuthenticatedBindings authenticate({
    required SecureKey key,
    required String vaultId,
    required String databaseId,
    required String keyId,
    required int generation,
  });
}

/// Argon2id passphrase/PIN wrapping port.
abstract interface class PassphraseWrappingPort {
  /// Wraps [key] under [passphrase] using [parameters]. Returns the opaque
  /// envelope persisted in [SecureMaterial.wrappedKey].
  String wrap({
    required SecureKey key,
    required String passphrase,
    required Argon2idParameters parameters,
    required AuthenticatedBindings bindings,
  });

  UnwrapOutcome unwrap({
    required String wrappedKey,
    required String passphrase,
    required Argon2idParameters parameters,
    required AuthenticatedBindings expectedBindings,
  });
}

/// Biometric-gated wrapping port (Android Keystore/iOS Secure Enclave).
abstract interface class BiometricWrappingPort {
  String enroll({
    required SecureKey key,
    required AuthenticatedBindings bindings,
  });

  UnwrapOutcome release({
    required String wrappedKey,
    required AuthenticatedBindings expectedBindings,
  });
}

/// Device secure-store wrapping port that can release without user presence.
abstract interface class DeviceSecureStorePort {
  String wrap({
    required SecureKey key,
    required AuthenticatedBindings bindings,
  });

  UnwrapOutcome release({
    required String wrappedKey,
    required AuthenticatedBindings expectedBindings,
  });
}

/// Whether supported secure storage and/or a configured passphrase fallback is
/// available on this platform. Drives the "unsupported platform, never
/// plaintext" policy (R-SEC-002).
final class VaultEnvironment {
  const VaultEnvironment({
    required this.secureStoreAvailable,
    required this.passphraseFallbackConfigured,
  });

  final bool secureStoreAvailable;
  final bool passphraseFallbackConfigured;

  bool supports(VaultProtection protection) => switch (protection) {
    VaultProtection.pinFallback => passphraseFallbackConfigured,
    VaultProtection.biometric ||
    VaultProtection.deviceSecureStore => secureStoreAvailable,
  };
}
