/// Production KeyVault fail-closed lifecycle state machine.
///
/// This orchestrates the ports in `key_vault_ports.dart` to implement the
/// full R-SEC-001/R-SEC-002 lifecycle: PIN Argon2id wrapping, biometric
/// release and enrollment invalidation, device secure-store release, bounded
/// retries, PIN change, crash-safe two-slot rotation, secure-store reset,
/// reinstall/restore detection, validated passphrase fallback, and explicit
/// deletion.
///
/// The spine invariant: an existing encrypted store can never trigger
/// replacement-key generation. A random profile key is minted only when the
/// state is [VaultAbsent] AND persistent storage is provably empty. Any other
/// discovery of ciphertext with missing/orphaned/mismatched material enters
/// [VaultRecoveryRequired] instead of minting a key.
library;

import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/key_vault_ports.dart';

/// Sealed production lifecycle states.
sealed class VaultState {
  const VaultState();

  /// Projection onto the DB-neutral [KeyVaultState] enum consumed by the
  /// runtime bootstrap and the app-lock gate.
  KeyVaultState get kind;
}

final class VaultAbsent extends VaultState {
  const VaultAbsent();
  @override
  KeyVaultState get kind => KeyVaultState.absent;
}

final class VaultCreating extends VaultState {
  const VaultCreating();
  @override
  KeyVaultState get kind => KeyVaultState.creating;
}

final class VaultAvailable extends VaultState {
  const VaultAvailable(this.material, this.key);
  final SecureMaterial material;
  final SecureKey key;
  @override
  KeyVaultState get kind => KeyVaultState.available;
}

final class VaultLocked extends VaultState {
  const VaultLocked(this.material, {required this.failedAttempts});
  final SecureMaterial material;
  final int failedAttempts;
  @override
  KeyVaultState get kind => KeyVaultState.locked;
}

/// The OS key policy currently refuses release (sensor unavailable, secret
/// service locked). Ciphertext is intact; the user can retry or unlock.
final class VaultPermissionRevoked extends VaultState {
  const VaultPermissionRevoked(this.material);
  final SecureMaterial material;
  @override
  KeyVaultState get kind => KeyVaultState.permissionRevoked;
}

final class VaultRetryLimited extends VaultState {
  const VaultRetryLimited(this.material, {required this.failedAttempts});
  final SecureMaterial material;
  final int failedAttempts;
  @override
  KeyVaultState get kind => KeyVaultState.retryLimited;
}

final class VaultRotating extends VaultState {
  const VaultRotating({
    required this.oldSlot,
    required this.newSlot,
    required this.oldMaterial,
    required this.newMaterial,
    required this.phase,
    this.oldKey,
    this.newKey,
  });

  final VaultSlot oldSlot;
  final VaultSlot newSlot;
  final SecureMaterial oldMaterial;
  final SecureMaterial newMaterial;
  final RotationPhase phase;
  final SecureKey? oldKey;
  final SecureKey? newKey;

  VaultRotating at(RotationPhase next, {SecureKey? oldKey, SecureKey? newKey}) {
    return VaultRotating(
      oldSlot: oldSlot,
      newSlot: newSlot,
      oldMaterial: oldMaterial,
      newMaterial: newMaterial,
      phase: next,
      oldKey: oldKey ?? this.oldKey,
      newKey: newKey ?? this.newKey,
    );
  }

  @override
  KeyVaultState get kind => KeyVaultState.rotating;
}

final class VaultRecoveryRequired extends VaultState {
  const VaultRecoveryRequired(this.reason);
  final VaultRecoveryReason reason;
  @override
  KeyVaultState get kind => KeyVaultState.recoveryRequired;
}

final class VaultDeleting extends VaultState {
  const VaultDeleting(this.confirmationToken, this.previous);
  final String confirmationToken;
  final VaultState previous;
  @override
  KeyVaultState get kind => KeyVaultState.deleting;
}

final class VaultDeleted extends VaultState {
  const VaultDeleted();
  @override
  KeyVaultState get kind => KeyVaultState.deleted;
}

/// Result of dispatching a [VaultEvent].
sealed class VaultActionResult {
  const VaultActionResult();
}

final class VaultStateChanged extends VaultActionResult {
  const VaultStateChanged(this.state);
  final VaultState state;
}

final class VaultKeyReleased extends VaultActionResult {
  const VaultKeyReleased(this.state, this.key);
  final VaultState state;
  final SecureKey key;
}

final class VaultRecoveryEntered extends VaultActionResult {
  const VaultRecoveryEntered(this.state);
  final VaultRecoveryRequired state;
}

final class VaultRejected extends VaultActionResult {
  const VaultRejected(this.reason);
  final VaultRejection reason;
}

/// Headless release skipped because user presence is required. No mutation.
final class VaultHeadlessSkipped extends VaultActionResult {
  const VaultHeadlessSkipped();
}

final class VaultDeletionCompleted extends VaultActionResult {
  const VaultDeletionCompleted();
}

/// Events the vault accepts.
sealed class VaultEvent {
  const VaultEvent();
}

final class InspectVault extends VaultEvent {
  const InspectVault();
}

final class CreateVault extends VaultEvent {
  const CreateVault({
    required this.databaseId,
    required this.protection,
    this.passphrase,
    this.parameters,
  });
  final String databaseId;
  final VaultProtection protection;
  final String? passphrase;
  final Argon2idParameters? parameters;
}

final class LockVault extends VaultEvent {
  const LockVault();
}

final class UnlockWithPassphrase extends VaultEvent {
  const UnlockWithPassphrase(this.passphrase);
  final String passphrase;
}

final class UnlockWithBiometric extends VaultEvent {
  const UnlockWithBiometric();
}

final class RetryWindowElapsed extends VaultEvent {
  const RetryWindowElapsed();
}

final class ClearPermissionBlock extends VaultEvent {
  const ClearPermissionBlock();
}

final class ChangePassphrase extends VaultEvent {
  const ChangePassphrase(this.newPassphrase, {this.parameters});
  final String newPassphrase;
  final Argon2idParameters? parameters;
}

final class HeadlessRelease extends VaultEvent {
  const HeadlessRelease();
}

final class StartRotation extends VaultEvent {
  const StartRotation({this.passphrase});
  final String? passphrase;
}

final class PrepareRotation extends VaultEvent {
  const PrepareRotation();
}

final class CommitDatabaseRotation extends VaultEvent {
  const CommitDatabaseRotation();
}

final class CommitVaultRotation extends VaultEvent {
  const CommitVaultRotation();
}

final class CompleteRotation extends VaultEvent {
  const CompleteRotation();
}

final class RecoverRotation extends VaultEvent {
  const RecoverRotation();
}

final class RequestDeletion extends VaultEvent {
  const RequestDeletion();
}

final class ConfirmDeletion extends VaultEvent {
  const ConfirmDeletion(this.token);
  final String token;
}

/// The production KeyVault state machine.
final class KeyVaultMachine {
  KeyVaultMachine({
    required this.storage,
    required this.environment,
    required this.random,
    required this.identifiers,
    required this.authenticator,
    required this.passphraseWrapping,
    required this.biometrics,
    required this.deviceSecureStore,
    this.maxPassphraseAttempts = 5,
  }) {
    _inspectOnBoot();
  }

  final VaultStoragePort storage;
  final VaultEnvironment environment;
  final RandomKeyPort random;
  final VaultIdentifierPort identifiers;
  final MetadataAuthenticatorPort authenticator;
  final PassphraseWrappingPort passphraseWrapping;
  final BiometricWrappingPort biometrics;
  final DeviceSecureStorePort deviceSecureStore;
  final int maxPassphraseAttempts;

  VaultState _state = const VaultAbsent();

  VaultState get state => _state;

  void _inspectOnBoot() {
    dispatch(const InspectVault());
  }

  VaultActionResult dispatch(VaultEvent event) => switch (event) {
    InspectVault() => _inspect(),
    CreateVault(
      :final databaseId,
      :final protection,
      :final passphrase,
      :final parameters,
    ) =>
      _createVault(
        databaseId: databaseId,
        protection: protection,
        passphrase: passphrase,
        parameters: parameters,
      ),
    LockVault() => _lock(),
    UnlockWithPassphrase(:final passphrase) => _unlockWithPassphrase(
      passphrase,
    ),
    UnlockWithBiometric() => _unlockWithBiometric(),
    RetryWindowElapsed() => _retryWindowElapsed(),
    ClearPermissionBlock() => _clearPermissionBlock(),
    ChangePassphrase(:final newPassphrase, :final parameters) =>
      _changePassphrase(newPassphrase, parameters),
    HeadlessRelease() => _headlessRelease(),
    StartRotation(:final passphrase) => _startRotation(passphrase: passphrase),
    PrepareRotation() => _prepareRotation(),
    CommitDatabaseRotation() => _commitDatabaseRotation(),
    CommitVaultRotation() => _commitVaultRotation(),
    CompleteRotation() => _completeRotation(),
    RecoverRotation() => _recoverRotation(),
    RequestDeletion() => _requestDeletion(),
    ConfirmDeletion(:final token) => _confirmDeletion(token),
  };

  bool get _isProvablyFreshInstallation =>
      storage.database == null &&
      storage.slots.isEmpty &&
      storage.activeSlot == null &&
      storage.rotation == null &&
      !storage.deletionMarker;

  VaultActionResult _inspect() {
    final RotationJournal? journal = storage.rotation;
    if (journal != null) {
      final SecureMaterial? oldMaterial = storage.slots[journal.oldSlot];
      final SecureMaterial? newMaterial = storage.slots[journal.newSlot];
      if (oldMaterial == null ||
          newMaterial == null ||
          storage.database == null) {
        return _recover(VaultRecoveryReason.rotationMetadataMismatch);
      }
      _state = VaultRotating(
        oldSlot: journal.oldSlot,
        newSlot: journal.newSlot,
        oldMaterial: oldMaterial,
        newMaterial: newMaterial,
        phase: journal.phase,
      );
      return VaultStateChanged(_state);
    }

    final VaultDatabaseMetadata? database = storage.database;
    final VaultSlot? slot = storage.activeSlot;
    final SecureMaterial? material = slot == null ? null : storage.slots[slot];
    if (database == null) {
      if (_isProvablyFreshInstallation) {
        _state = const VaultAbsent();
        return VaultStateChanged(_state);
      }
      // Orphaned secure material or a stray deletion marker with no database:
      // never treated as a fresh install.
      return _recover(VaultRecoveryReason.orphanedSecureMaterial);
    }
    if (material == null) {
      // Ciphertext exists but its wrapped key is gone (secure-store reset,
      // reinstall, restored database without material).
      return _recover(VaultRecoveryReason.secureMaterialMissing);
    }
    if (!environment.supports(material.protection)) {
      return _recover(VaultRecoveryReason.protectionUnavailable);
    }
    final VaultRecoveryReason? mismatch = _metadataMismatch(database, material);
    if (mismatch != null) {
      return _recover(mismatch);
    }
    _state = VaultLocked(material, failedAttempts: 0);
    return VaultStateChanged(_state);
  }

  VaultActionResult _createVault({
    required String databaseId,
    required VaultProtection protection,
    String? passphrase,
    Argon2idParameters? parameters,
  }) {
    // Key generation is permitted only when every persistent vault artifact is
    // absent. `state is VaultAbsent` alone is insufficient because callers can
    // dispatch creation before startup inspection classifies orphaned or
    // partially restored storage.
    if (_state is! VaultAbsent || !_isProvablyFreshInstallation) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    if (!environment.supports(protection)) {
      // Neither supported secure storage nor a configured fallback exists.
      // Plaintext fallback is prohibited; this platform is unsupported.
      return const VaultRejected(VaultRejection.plaintextProhibited);
    }
    if (protection == VaultProtection.pinFallback &&
        (passphrase == null || passphrase.isEmpty)) {
      return const VaultRejected(VaultRejection.credentialRequired);
    }
    final Argon2idParameters effectiveParameters =
        parameters ?? Argon2idParameters.pinV1;
    if (protection == VaultProtection.pinFallback &&
        !effectiveParameters.isWithinPolicy) {
      return const VaultRejected(VaultRejection.plaintextProhibited);
    }

    _state = const VaultCreating();

    final SecureKey key = random.generateProfileKey();
    final String vaultId = identifiers.nextVaultId();
    final String keyId = identifiers.nextKeyId();
    final AuthenticatedBindings bindings = authenticator.authenticate(
      key: key,
      vaultId: vaultId,
      databaseId: databaseId,
      keyId: keyId,
      generation: 1,
    );
    final String? wrapped = _wrap(
      protection: protection,
      key: key,
      bindings: bindings,
      passphrase: passphrase,
      parameters: effectiveParameters,
    );
    if (wrapped == null) {
      _state = const VaultAbsent();
      return const VaultRejected(VaultRejection.credentialRequired);
    }
    final SecureMaterial material = SecureMaterial(
      vaultVersion: 1,
      databaseVersion: 1,
      keyVersion: 1,
      generationVersion: 1,
      vaultId: vaultId,
      databaseId: databaseId,
      keyId: keyId,
      generation: 1,
      bindings: bindings,
      protection: protection,
      wrappedKey: wrapped,
      parameters: protection == VaultProtection.pinFallback
          ? effectiveParameters
          : null,
    );
    storage
      ..writeSlot(VaultSlot.a, material)
      ..activeSlot = VaultSlot.a
      ..database = material.metadata;
    _state = VaultAvailable(material, key);
    return VaultKeyReleased(_state, key);
  }

  VaultActionResult _lock() {
    final VaultState current = _state;
    if (current is! VaultAvailable) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    current.key.destroy();
    _state = VaultLocked(current.material, failedAttempts: 0);
    return VaultStateChanged(_state);
  }

  VaultActionResult _unlockWithPassphrase(String passphrase) {
    final VaultState current = _state;
    if (current is VaultRetryLimited) {
      return const VaultRejected(VaultRejection.retryLimitReached);
    }
    if (current is! VaultLocked ||
        current.material.protection != VaultProtection.pinFallback) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final Argon2idParameters? parameters = current.material.parameters;
    if (parameters == null || !parameters.isWithinPolicy) {
      return _recover(VaultRecoveryReason.parametersOutOfPolicy);
    }
    final UnwrapOutcome released = passphraseWrapping.unwrap(
      wrappedKey: current.material.wrappedKey,
      passphrase: passphrase,
      parameters: parameters,
      expectedBindings: current.material.bindings,
    );
    return _handlePassphraseRelease(released, current);
  }

  VaultActionResult _unlockWithBiometric() {
    final VaultState current = _state;
    if (current is! VaultLocked ||
        current.material.protection != VaultProtection.biometric) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final UnwrapOutcome released = biometrics.release(
      wrappedKey: current.material.wrappedKey,
      expectedBindings: current.material.bindings,
    );
    return _handlePresenceRelease(released, current.material);
  }

  VaultActionResult _retryWindowElapsed() {
    final VaultState current = _state;
    if (current is! VaultRetryLimited) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    _state = VaultLocked(current.material, failedAttempts: 0);
    return VaultStateChanged(_state);
  }

  VaultActionResult _clearPermissionBlock() {
    final VaultState current = _state;
    if (current is! VaultPermissionRevoked) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    _state = VaultLocked(current.material, failedAttempts: 0);
    return VaultStateChanged(_state);
  }

  VaultActionResult _changePassphrase(
    String newPassphrase,
    Argon2idParameters? parameters,
  ) {
    final VaultState current = _state;
    if (current is! VaultAvailable ||
        current.material.protection != VaultProtection.pinFallback ||
        newPassphrase.isEmpty) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final Argon2idParameters effectiveParameters =
        parameters ?? current.material.parameters ?? Argon2idParameters.pinV1;
    if (!effectiveParameters.isWithinPolicy) {
      return const VaultRejected(VaultRejection.plaintextProhibited);
    }
    final String wrapped = passphraseWrapping.wrap(
      key: current.key,
      passphrase: newPassphrase,
      parameters: effectiveParameters,
      bindings: current.material.bindings,
    );
    // Rewrapping changes only the envelope, never the key/database identity.
    final SecureMaterial updated = current.material.copyWith(
      wrappedKey: wrapped,
      parameters: effectiveParameters,
    );
    storage.writeSlot(storage.activeSlot!, updated);
    _state = VaultAvailable(updated, current.key);
    return VaultStateChanged(_state);
  }

  VaultActionResult _headlessRelease() {
    final VaultState current = _state;
    final SecureMaterial? material = switch (current) {
      VaultAvailable(:final material) => material,
      VaultLocked(:final material) => material,
      _ => null,
    };
    if (material == null) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    if (material.requiresUserPresence) {
      // App-lock gate: background work skips safely when release needs a user.
      return const VaultHeadlessSkipped();
    }
    if (current is VaultAvailable) {
      return VaultKeyReleased(current, current.key);
    }
    final UnwrapOutcome released = deviceSecureStore.release(
      wrappedKey: material.wrappedKey,
      expectedBindings: material.bindings,
    );
    return _handlePresenceRelease(released, material);
  }

  VaultActionResult _startRotation({String? passphrase}) {
    final VaultState current = _state;
    if (current is! VaultAvailable) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final SecureMaterial old = current.material;
    Argon2idParameters? nextParameters;
    if (old.protection == VaultProtection.pinFallback) {
      if (passphrase == null || passphrase.isEmpty) {
        return const VaultRejected(VaultRejection.credentialRequired);
      }
      nextParameters = old.parameters ?? Argon2idParameters.pinV1;
      if (!nextParameters.isWithinPolicy) {
        return const VaultRejected(VaultRejection.plaintextProhibited);
      }
    }
    final SecureKey candidate = random.generateProfileKey();
    final String keyId = identifiers.nextKeyId();
    final int generation = old.generation + 1;
    final AuthenticatedBindings bindings = authenticator.authenticate(
      key: candidate,
      vaultId: old.vaultId,
      databaseId: old.databaseId,
      keyId: keyId,
      generation: generation,
    );
    final String? wrapped = _wrap(
      protection: old.protection,
      key: candidate,
      bindings: bindings,
      passphrase: passphrase,
      parameters: nextParameters,
    );
    if (wrapped == null) {
      candidate.destroy();
      return const VaultRejected(VaultRejection.credentialRequired);
    }
    final SecureMaterial next = old.copyWith(
      keyId: keyId,
      generation: generation,
      bindings: bindings,
      wrappedKey: wrapped,
      parameters: nextParameters,
    );
    final VaultSlot oldSlot = storage.activeSlot!;
    _state = VaultRotating(
      oldSlot: oldSlot,
      newSlot: oldSlot.other,
      oldMaterial: old,
      newMaterial: next,
      phase: RotationPhase.draft,
      oldKey: current.key,
      newKey: candidate,
    );
    return VaultStateChanged(_state);
  }

  VaultActionResult _prepareRotation() {
    final VaultState current = _state;
    if (current is! VaultRotating || current.phase != RotationPhase.draft) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    storage
      ..writeSlot(current.newSlot, current.newMaterial)
      ..rotation = RotationJournal(
        oldSlot: current.oldSlot,
        newSlot: current.newSlot,
        phase: RotationPhase.prepared,
      );
    _state = current.at(RotationPhase.prepared);
    return VaultStateChanged(_state);
  }

  VaultActionResult _commitDatabaseRotation() {
    final VaultState current = _state;
    if (current is! VaultRotating || current.phase != RotationPhase.prepared) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    storage
      ..database = current.newMaterial.metadata
      ..rotation = storage.rotation!.at(RotationPhase.databaseCommitted);
    _state = current.at(RotationPhase.databaseCommitted);
    return VaultStateChanged(_state);
  }

  VaultActionResult _commitVaultRotation() {
    final VaultState current = _state;
    if (current is! VaultRotating ||
        current.phase != RotationPhase.databaseCommitted) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    storage
      ..activeSlot = current.newSlot
      ..rotation = storage.rotation!.at(RotationPhase.vaultCommitted);
    _state = current.at(RotationPhase.vaultCommitted);
    return VaultStateChanged(_state);
  }

  VaultActionResult _completeRotation() {
    final VaultState current = _state;
    if (current is! VaultRotating ||
        current.phase != RotationPhase.vaultCommitted) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    storage
      ..removeSlot(current.oldSlot)
      ..rotation = null;
    current.oldKey?.destroy();
    final SecureKey? newKey = current.newKey;
    if (newKey == null) {
      _state = VaultLocked(current.newMaterial, failedAttempts: 0);
      return VaultStateChanged(_state);
    }
    _state = VaultAvailable(current.newMaterial, newKey);
    return VaultKeyReleased(_state, newKey);
  }

  VaultActionResult _recoverRotation() {
    final VaultState current = _state;
    if (current is! VaultRotating || current.phase == RotationPhase.draft) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final VaultDatabaseMetadata? database = storage.database;
    if (database == null) {
      return _recover(VaultRecoveryReason.rotationMetadataMismatch);
    }
    final bool matchesOld =
        _metadataMismatch(database, current.oldMaterial) == null;
    final bool matchesNew =
        _metadataMismatch(database, current.newMaterial) == null;

    if (current.phase == RotationPhase.prepared && matchesOld) {
      // Database never rekeyed: roll the uncommitted candidate back.
      storage
        ..removeSlot(current.newSlot)
        ..activeSlot = current.oldSlot
        ..rotation = null;
      _state = VaultLocked(current.oldMaterial, failedAttempts: 0);
      return VaultStateChanged(_state);
    }
    if (matchesNew) {
      // Database is on the new key: promote the prepared candidate and clean
      // the old slot.
      storage
        ..activeSlot = current.newSlot
        ..removeSlot(current.oldSlot)
        ..rotation = null;
      _state = VaultLocked(current.newMaterial, failedAttempts: 0);
      return VaultStateChanged(_state);
    }
    return _recover(VaultRecoveryReason.rotationMetadataMismatch);
  }

  VaultActionResult _requestDeletion() {
    final VaultState current = _state;
    if (current is VaultAbsent ||
        current is VaultDeleted ||
        current is VaultDeleting) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    final String vaultId = switch (current) {
      VaultAvailable(:final material) ||
      VaultLocked(:final material) ||
      VaultPermissionRevoked(:final material) ||
      VaultRetryLimited(:final material) => material.vaultId,
      VaultRotating(:final oldMaterial) => oldMaterial.vaultId,
      VaultRecoveryRequired() =>
        storage.slots.values.isEmpty
            ? 'unknown'
            : storage.slots.values.first.vaultId,
      _ => 'unknown',
    };
    final String token = 'DELETE:$vaultId';
    storage.deletionMarker = true;
    _state = VaultDeleting(token, current);
    return VaultStateChanged(_state);
  }

  VaultActionResult _confirmDeletion(String token) {
    final VaultState current = _state;
    if (current is! VaultDeleting) {
      return const VaultRejected(VaultRejection.invalidTransition);
    }
    if (token != current.confirmationToken) {
      return const VaultRejected(VaultRejection.deletionTokenMismatch);
    }
    final VaultState previous = current.previous;
    if (previous is VaultAvailable) {
      previous.key.destroy();
    }
    storage.clearAll();
    _state = const VaultDeleted();
    return const VaultDeletionCompleted();
  }

  VaultActionResult _handlePassphraseRelease(
    UnwrapOutcome released,
    VaultLocked current,
  ) {
    return switch (released) {
      UnwrapSucceeded(:final key) => _released(current.material, key),
      UnwrapCredentialInvalidated() => _recover(
        VaultRecoveryReason.credentialInvalidated,
      ),
      UnwrapUnavailable() => _permissionRevoked(current.material),
      UnwrapInvalidCredential() => _passphraseFailed(current),
    };
  }

  VaultActionResult _handlePresenceRelease(
    UnwrapOutcome released,
    SecureMaterial material,
  ) {
    return switch (released) {
      UnwrapSucceeded(:final key) => _released(material, key),
      UnwrapCredentialInvalidated() => _recover(
        VaultRecoveryReason.credentialInvalidated,
      ),
      UnwrapUnavailable() => _permissionRevoked(material),
      // A presence-gated store never reports a "wrong credential"; treat it as
      // a transient permission block rather than a retry-limited failure.
      UnwrapInvalidCredential() => _permissionRevoked(material),
    };
  }

  VaultActionResult _released(SecureMaterial material, SecureKey key) {
    _state = VaultAvailable(material, key);
    return VaultKeyReleased(_state, key);
  }

  VaultActionResult _permissionRevoked(SecureMaterial material) {
    _state = VaultPermissionRevoked(material);
    return VaultStateChanged(_state);
  }

  VaultActionResult _passphraseFailed(VaultLocked current) {
    final int failures = current.failedAttempts + 1;
    if (failures >= maxPassphraseAttempts) {
      _state = VaultRetryLimited(current.material, failedAttempts: failures);
    } else {
      _state = VaultLocked(current.material, failedAttempts: failures);
    }
    return VaultStateChanged(_state);
  }

  String? _wrap({
    required VaultProtection protection,
    required SecureKey key,
    required AuthenticatedBindings bindings,
    String? passphrase,
    Argon2idParameters? parameters,
  }) => switch (protection) {
    VaultProtection.pinFallback when passphrase != null && parameters != null =>
      passphraseWrapping.wrap(
        key: key,
        passphrase: passphrase,
        parameters: parameters,
        bindings: bindings,
      ),
    VaultProtection.pinFallback => null,
    VaultProtection.biometric => biometrics.enroll(
      key: key,
      bindings: bindings,
    ),
    VaultProtection.deviceSecureStore => deviceSecureStore.wrap(
      key: key,
      bindings: bindings,
    ),
  };

  VaultActionResult _recover(VaultRecoveryReason reason) {
    final VaultRecoveryRequired recovery = VaultRecoveryRequired(reason);
    _state = recovery;
    return VaultRecoveryEntered(recovery);
  }
}

/// Compares the database's recorded identity against the wrapped material.
/// Any divergence yields a fail-closed recovery reason.
VaultRecoveryReason? _metadataMismatch(
  VaultDatabaseMetadata database,
  SecureMaterial material,
) {
  if (database.vaultVersion != 1 || material.vaultVersion != 1) {
    return VaultRecoveryReason.unsupportedVaultVersion;
  }
  if (database.databaseVersion != material.databaseVersion) {
    return VaultRecoveryReason.databaseVersionMismatch;
  }
  if (database.keyVersion != material.keyVersion) {
    return VaultRecoveryReason.keyVersionMismatch;
  }
  if (database.generationVersion != material.generationVersion) {
    return VaultRecoveryReason.generationVersionMismatch;
  }
  if (database.vaultId != material.vaultId) {
    return VaultRecoveryReason.vaultIdMismatch;
  }
  if (database.databaseId != material.databaseId) {
    return VaultRecoveryReason.databaseIdMismatch;
  }
  if (database.keyId != material.keyId) {
    return VaultRecoveryReason.keyIdMismatch;
  }
  if (database.generation != material.generation) {
    return VaultRecoveryReason.generationMismatch;
  }
  if (database.bindings.sentinelTag != material.bindings.sentinelTag) {
    return VaultRecoveryReason.sentinelMismatch;
  }
  if (database.bindings.keyFingerprint != material.bindings.keyFingerprint) {
    return VaultRecoveryReason.fingerprintMismatch;
  }
  return null;
}
