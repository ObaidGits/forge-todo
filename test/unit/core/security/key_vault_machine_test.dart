import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/key_vault_machine.dart';
import 'package:forge/core/security/key_vault_ports.dart';
import 'package:forge/core/security/machine_backed_key_vault.dart';

import '../../../helpers/fake_key_vault_ports.dart';

/// Test harness that owns durable storage and can rebuild the machine to
/// simulate a process restart (which re-runs boot inspection).
final class VaultHarness {
  VaultHarness(this.environment, {this.maxPassphraseAttempts = 5}) {
    machine = _build();
  }

  factory VaultHarness.pin() => VaultHarness(
    const VaultEnvironment(
      secureStoreAvailable: false,
      passphraseFallbackConfigured: true,
    ),
  );

  factory VaultHarness.biometric() => VaultHarness(
    const VaultEnvironment(
      secureStoreAvailable: true,
      passphraseFallbackConfigured: false,
    ),
  );

  factory VaultHarness.device() => VaultHarness(
    const VaultEnvironment(
      secureStoreAvailable: true,
      passphraseFallbackConfigured: false,
    ),
  );

  factory VaultHarness.unsupported() => VaultHarness(
    const VaultEnvironment(
      secureStoreAvailable: false,
      passphraseFallbackConfigured: false,
    ),
  );

  VaultEnvironment environment;
  final int maxPassphraseAttempts;
  final InMemoryVaultStorage storage = InMemoryVaultStorage();
  final FakeRandomKeyPort random = FakeRandomKeyPort();
  final FakeVaultIdentifierPort identifiers = FakeVaultIdentifierPort();
  final FakeMetadataAuthenticator authenticator = FakeMetadataAuthenticator();
  final FakePassphraseWrapping passphrase = FakePassphraseWrapping();
  final FakeBiometricWrapping biometrics = FakeBiometricWrapping();
  final FakeDeviceSecureStore device = FakeDeviceSecureStore();
  late KeyVaultMachine machine;

  KeyVaultMachine _build() => KeyVaultMachine(
    storage: storage,
    environment: environment,
    random: random,
    identifiers: identifiers,
    authenticator: authenticator,
    passphraseWrapping: passphrase,
    biometrics: biometrics,
    deviceSecureStore: device,
    maxPassphraseAttempts: maxPassphraseAttempts,
  );

  /// Rebuilds the machine against the same storage and returns the boot
  /// inspection result.
  VaultActionResult restart() {
    machine = _build();
    return machine.dispatch(const InspectVault());
  }

  void replaceEnvironment(VaultEnvironment next) {
    environment = next;
    machine = _build();
  }

  void createPin({String databaseId = 'database-1'}) {
    expect(
      machine.dispatch(
        CreateVault(
          databaseId: databaseId,
          protection: VaultProtection.pinFallback,
          passphrase: '1234',
        ),
      ),
      isA<VaultKeyReleased>(),
    );
  }

  void createBiometric() {
    expect(
      machine.dispatch(
        const CreateVault(
          databaseId: 'database-1',
          protection: VaultProtection.biometric,
        ),
      ),
      isA<VaultKeyReleased>(),
    );
  }

  void createDevice() {
    expect(
      machine.dispatch(
        const CreateVault(
          databaseId: 'database-1',
          protection: VaultProtection.deviceSecureStore,
        ),
      ),
      isA<VaultKeyReleased>(),
    );
  }
}

void expectRecovery(VaultActionResult result, VaultRecoveryReason reason) {
  expect(
    result,
    isA<VaultRecoveryEntered>().having(
      (VaultRecoveryEntered value) => value.state.reason,
      'reason',
      reason,
    ),
  );
}

void expectNoReplacement(VaultHarness harness, int expected) {
  expect(harness.random.generateCalls, expected);
}

void main() {
  group('bootstrap and key generation', () {
    test('fresh vault mints exactly one random key and releases it', () {
      final VaultHarness harness = VaultHarness.pin();

      final VaultActionResult result = harness.machine.dispatch(
        const CreateVault(
          databaseId: 'database-1',
          protection: VaultProtection.pinFallback,
          passphrase: '1234',
        ),
      );

      expect(result, isA<VaultKeyReleased>());
      expect(harness.machine.state, isA<VaultAvailable>());
      expect(harness.random.generateCalls, 1);
      expect(harness.storage.database!.generation, 1);
      expect(harness.storage.database!.bindings.sentinelTag, isNotEmpty);
      expect(harness.storage.database!.bindings.keyFingerprint, isNotEmpty);
    });

    test('created pin material stores only a wrapped envelope, no raw key', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final SecureMaterial material = harness.storage.slots.values.single;
      final String rawKey = harness.random
          .generateProfileKey()
          .copyBytes()
          .toString();

      expect(material.protection, VaultProtection.pinFallback);
      expect(material.wrappedKey, startsWith('pin-envelope-'));
      expect(material.wrappedKey, isNot(contains(rawKey)));
      expect(material.parameters!.sameAs(Argon2idParameters.pinV1), isTrue);
      expect(material.requiresUserPresence, isTrue);
    });
  });

  group('fail-closed discovery (no replacement key)', () {
    test('a second create is rejected and mints no new key', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();

      final VaultActionResult result = harness.machine.dispatch(
        const CreateVault(
          databaseId: 'database-2',
          protection: VaultProtection.pinFallback,
          passphrase: '9999',
        ),
      );

      expect(result, isA<VaultRejected>());
      expect(harness.random.generateCalls, 1);
    });

    test('every persisted-artifact shape blocks replacement creation', () {
      for (int mask = 1; mask < 1 << 5; mask++) {
        final VaultHarness harness = VaultHarness.pin()..createPin();
        final VaultDatabaseMetadata database = harness.storage.database!;
        final SecureMaterial material =
            harness.storage.slots[harness.storage.activeSlot!]!;
        harness.storage.clearAll();

        if (mask & 1 != 0) harness.storage.database = database;
        if (mask & 2 != 0) harness.storage.writeSlot(VaultSlot.a, material);
        if (mask & 4 != 0) harness.storage.activeSlot = VaultSlot.a;
        if (mask & 8 != 0) {
          harness.storage.rotation = const RotationJournal(
            oldSlot: VaultSlot.a,
            newSlot: VaultSlot.b,
            phase: RotationPhase.prepared,
          );
        }
        if (mask & 16 != 0) harness.storage.deletionMarker = true;

        harness.restart();
        final VaultActionResult beforeInspect = harness.machine.dispatch(
          const CreateVault(
            databaseId: 'replacement',
            protection: VaultProtection.pinFallback,
            passphrase: '9999',
          ),
        );

        expect(
          beforeInspect,
          isA<VaultRejected>().having(
            (VaultRejected r) => r.reason,
            'reason for mask $mask',
            VaultRejection.invalidTransition,
          ),
        );
        expect(harness.random.generateCalls, 1, reason: 'mask $mask');
      }
    });

    test('secure-store reset with ciphertext enters recovery', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.storage.slots.clear();

      expectRecovery(
        harness.restart(),
        VaultRecoveryReason.secureMaterialMissing,
      );
      expectNoReplacement(harness, 1);
    });

    test('reinstall/restored database without material enters recovery', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.storage
        ..slots.clear()
        ..activeSlot = null;

      expectRecovery(
        harness.restart(),
        VaultRecoveryReason.secureMaterialMissing,
      );
      expectNoReplacement(harness, 1);
    });

    test('orphaned secure material is not a fresh install', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.storage.database = null;

      expectRecovery(
        harness.restart(),
        VaultRecoveryReason.orphanedSecureMaterial,
      );
      expectNoReplacement(harness, 1);
    });

    final List<_MismatchCase> mismatches = <_MismatchCase>[
      _MismatchCase(
        'vault version',
        VaultRecoveryReason.unsupportedVaultVersion,
        (VaultDatabaseMetadata db) => db.copyWith(vaultVersion: 2),
      ),
      _MismatchCase(
        'database version',
        VaultRecoveryReason.databaseVersionMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(databaseVersion: 2),
      ),
      _MismatchCase(
        'key version',
        VaultRecoveryReason.keyVersionMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(keyVersion: 2),
      ),
      _MismatchCase(
        'generation version',
        VaultRecoveryReason.generationVersionMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(generationVersion: 2),
      ),
      _MismatchCase(
        'vault id',
        VaultRecoveryReason.vaultIdMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(vaultId: 'restored'),
      ),
      _MismatchCase(
        'database id',
        VaultRecoveryReason.databaseIdMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(databaseId: 'copied'),
      ),
      _MismatchCase(
        'key id',
        VaultRecoveryReason.keyIdMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(keyId: 'other'),
      ),
      _MismatchCase(
        'generation',
        VaultRecoveryReason.generationMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(generation: 99),
      ),
      _MismatchCase(
        'sentinel',
        VaultRecoveryReason.sentinelMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(
          bindings: db.bindings.copyWith(sentinelTag: 'tampered'),
        ),
      ),
      _MismatchCase(
        'fingerprint',
        VaultRecoveryReason.fingerprintMismatch,
        (VaultDatabaseMetadata db) => db.copyWith(
          bindings: db.bindings.copyWith(keyFingerprint: 'wrong'),
        ),
      ),
    ];

    for (final _MismatchCase mismatch in mismatches) {
      test('${mismatch.name} mismatch enters recovery without replacement', () {
        final VaultHarness harness = VaultHarness.pin()..createPin();
        harness.storage.database = mismatch.mutate(harness.storage.database!);

        expectRecovery(harness.restart(), mismatch.reason);
        expectNoReplacement(harness, 1);
      });
    }

    test('OS restore combining database and other vault material fails', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final SecureMaterial foreign = harness.storage.slots.values.single
          .copyWith();
      // Simulate restored material bound to a different vault identity.
      harness.storage.writeSlot(
        harness.storage.activeSlot!,
        _withVaultId(foreign, 'restored-vault'),
      );

      expectRecovery(harness.restart(), VaultRecoveryReason.vaultIdMismatch);
    });
  });

  group('lock, release, and bounded retries', () {
    test('valid restart is locked and the correct PIN releases the key', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();

      expect(harness.restart(), isA<VaultStateChanged>());
      expect(harness.machine.state, isA<VaultLocked>());
      expect(
        harness.machine.dispatch(const UnlockWithPassphrase('1234')),
        isA<VaultKeyReleased>(),
      );
      expect(harness.machine.state, isA<VaultAvailable>());
    });

    test('PIN retries are bounded and the cooldown resets the window', () {
      final VaultHarness harness = VaultHarness(
        const VaultEnvironment(
          secureStoreAvailable: false,
          passphraseFallbackConfigured: true,
        ),
        maxPassphraseAttempts: 3,
      )..createPin();
      harness.restart();

      harness.machine.dispatch(const UnlockWithPassphrase('bad-1'));
      expect((harness.machine.state as VaultLocked).failedAttempts, 1);
      harness.machine.dispatch(const UnlockWithPassphrase('bad-2'));
      expect((harness.machine.state as VaultLocked).failedAttempts, 2);
      harness.machine.dispatch(const UnlockWithPassphrase('bad-3'));
      expect(harness.machine.state, isA<VaultRetryLimited>());
      expect(
        harness.machine.dispatch(const UnlockWithPassphrase('1234')),
        isA<VaultRejected>().having(
          (VaultRejected r) => r.reason,
          'reason',
          VaultRejection.retryLimitReached,
        ),
      );

      harness.machine.dispatch(const RetryWindowElapsed());
      expect(harness.machine.state, isA<VaultLocked>());
      expect(
        harness.machine.dispatch(const UnlockWithPassphrase('1234')),
        isA<VaultKeyReleased>(),
      );
    });

    test('PIN change rewraps without changing key metadata', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final VaultDatabaseMetadata before = harness.storage.database!;

      expect(
        harness.machine.dispatch(const ChangePassphrase('5678')),
        isA<VaultStateChanged>(),
      );
      harness.machine.dispatch(const LockVault());
      expect(
        harness.machine.dispatch(const UnlockWithPassphrase('1234')),
        isA<VaultStateChanged>(),
      );
      expect(
        harness.machine.dispatch(const UnlockWithPassphrase('5678')),
        isA<VaultKeyReleased>(),
      );
      expect(harness.storage.database!.keyId, before.keyId);
      expect(harness.storage.database!.generation, before.generation);
      expect(harness.random.generateCalls, 1);
    });

    test('out-of-policy stored parameters fail closed on unlock', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final SecureMaterial weak = harness.storage.slots.values.single.copyWith(
        parameters: const Argon2idParameters(
          memoryKiB: 1024,
          iterations: 1,
          parallelism: 1,
          saltLength: 8,
          keyLength: 16,
        ),
      );
      harness.storage.writeSlot(harness.storage.activeSlot!, weak);
      harness.restart();

      expectRecovery(
        harness.machine.dispatch(const UnlockWithPassphrase('1234')),
        VaultRecoveryReason.parametersOutOfPolicy,
      );
    });
  });

  group('biometric release and enrollment invalidation', () {
    test('biometric success releases the key', () {
      final VaultHarness harness = VaultHarness.biometric()..createBiometric();
      harness.machine.dispatch(const LockVault());

      expect(
        harness.machine.dispatch(const UnlockWithBiometric()),
        isA<VaultKeyReleased>(),
      );
      expect(harness.machine.state, isA<VaultAvailable>());
    });

    for (final ReleaseOutcome outcome in <ReleaseOutcome>[
      ReleaseOutcome.unavailable,
      ReleaseOutcome.cancelled,
    ]) {
      test('biometric $outcome yields a clearable permission block', () {
        final VaultHarness harness = VaultHarness.biometric()
          ..createBiometric();
        harness.machine.dispatch(const LockVault());
        harness.biometrics.nextOutcome = outcome;

        expect(
          harness.machine.dispatch(const UnlockWithBiometric()),
          isA<VaultStateChanged>(),
        );
        expect(harness.machine.state, isA<VaultPermissionRevoked>());
        expect(
          harness.machine.dispatch(const ClearPermissionBlock()),
          isA<VaultStateChanged>(),
        );
        expect(harness.machine.state, isA<VaultLocked>());
        expectNoReplacement(harness, 1);
      });
    }

    test('biometric enrollment invalidation enters recovery', () {
      final VaultHarness harness = VaultHarness.biometric()..createBiometric();
      harness.machine.dispatch(const LockVault());
      harness.biometrics.nextOutcome = ReleaseOutcome.invalidated;

      expectRecovery(
        harness.machine.dispatch(const UnlockWithBiometric()),
        VaultRecoveryReason.credentialInvalidated,
      );
      expectNoReplacement(harness, 1);
    });
  });

  group('headless / background release policy', () {
    test('headless release skips when PIN presence is required', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.machine.dispatch(const LockVault());

      expect(
        harness.machine.dispatch(const HeadlessRelease()),
        isA<VaultHeadlessSkipped>(),
      );
      expect(harness.machine.state, isA<VaultLocked>());
    });

    test('headless release skips when biometric presence is required', () {
      final VaultHarness harness = VaultHarness.biometric()..createBiometric();
      harness.machine.dispatch(const LockVault());

      expect(
        harness.machine.dispatch(const HeadlessRelease()),
        isA<VaultHeadlessSkipped>(),
      );
      expect(harness.machine.state, isA<VaultLocked>());
    });

    test('headless release succeeds for a no-presence device policy', () {
      final VaultHarness harness = VaultHarness.device()..createDevice();
      harness.machine.dispatch(const LockVault());

      expect(
        harness.machine.dispatch(const HeadlessRelease()),
        isA<VaultKeyReleased>(),
      );
      expect(harness.machine.state, isA<VaultAvailable>());
    });

    test('device protection invalidation enters recovery', () {
      final VaultHarness harness = VaultHarness.device()..createDevice();
      harness.machine.dispatch(const LockVault());
      harness.device.invalidated = true;

      expectRecovery(
        harness.machine.dispatch(const HeadlessRelease()),
        VaultRecoveryReason.credentialInvalidated,
      );
      expectNoReplacement(harness, 1);
    });
  });

  group('validated passphrase fallback policy', () {
    test('no secure store and no fallback rejects creation (no plaintext)', () {
      final VaultHarness harness = VaultHarness.unsupported();

      final VaultActionResult result = harness.machine.dispatch(
        const CreateVault(
          databaseId: 'database-1',
          protection: VaultProtection.pinFallback,
          passphrase: '1234',
        ),
      );

      expect(
        result,
        isA<VaultRejected>().having(
          (VaultRejected r) => r.reason,
          'reason',
          VaultRejection.plaintextProhibited,
        ),
      );
      expect(harness.storage.database, isNull);
      expect(harness.random.generateCalls, 0);
    });

    test('out-of-policy Argon2id parameters are rejected at creation', () {
      final VaultHarness harness = VaultHarness.pin();

      final VaultActionResult result = harness.machine.dispatch(
        const CreateVault(
          databaseId: 'database-1',
          protection: VaultProtection.pinFallback,
          passphrase: '1234',
          parameters: Argon2idParameters(
            memoryKiB: 256,
            iterations: 1,
            parallelism: 1,
            saltLength: 8,
            keyLength: 16,
          ),
        ),
      );

      expect(result, isA<VaultRejected>());
      expect(harness.storage.database, isNull);
      expect(harness.random.generateCalls, 0);
    });

    test('existing database with now-unavailable fallback enters recovery', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.replaceEnvironment(
        const VaultEnvironment(
          secureStoreAvailable: false,
          passphraseFallbackConfigured: false,
        ),
      );

      expectRecovery(
        harness.machine.dispatch(const InspectVault()),
        VaultRecoveryReason.protectionUnavailable,
      );
      expectNoReplacement(harness, 1);
    });
  });

  group('crash-safe two-slot rotation', () {
    test('happy path prepares, commits db, commits vault, completes', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final String oldKeyId = harness.storage.database!.keyId;

      harness.machine.dispatch(const StartRotation(passphrase: '1234'));
      expect(
        (harness.machine.state as VaultRotating).phase,
        RotationPhase.draft,
      );
      expect(harness.storage.rotation, isNull);
      harness.machine.dispatch(const PrepareRotation());
      expect(harness.storage.slots, hasLength(2));
      expect(harness.storage.rotation!.phase, RotationPhase.prepared);
      harness.machine.dispatch(const CommitDatabaseRotation());
      expect(harness.storage.rotation!.phase, RotationPhase.databaseCommitted);
      harness.machine.dispatch(const CommitVaultRotation());
      expect(harness.storage.rotation!.phase, RotationPhase.vaultCommitted);
      expect(
        harness.machine.dispatch(const CompleteRotation()),
        isA<VaultKeyReleased>(),
      );

      expect(harness.storage.slots, hasLength(1));
      expect(harness.storage.rotation, isNull);
      expect(harness.storage.database!.keyId, isNot(oldKeyId));
      expect(harness.storage.database!.generation, 2);
      expect(harness.random.generateCalls, 2);
    });

    test('crash before prepare retains the old committed slot', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final String oldKeyId = harness.storage.database!.keyId;
      harness.machine.dispatch(const StartRotation(passphrase: '1234'));

      harness.restart();

      expect(harness.machine.state, isA<VaultLocked>());
      expect(harness.storage.database!.keyId, oldKeyId);
      expect(harness.storage.slots, hasLength(1));
      expect(harness.storage.rotation, isNull);
    });

    test('crash after prepare rolls the uncommitted candidate back', () {
      final VaultHarness harness = _prepared();
      final String oldKeyId = harness.storage.database!.keyId;

      expect(harness.restart(), isA<VaultStateChanged>());
      expect(harness.machine.state, isA<VaultRotating>());
      expect(
        harness.machine.dispatch(const RecoverRotation()),
        isA<VaultStateChanged>(),
      );

      expect(harness.machine.state, isA<VaultLocked>());
      expect(harness.storage.database!.keyId, oldKeyId);
      expect(harness.storage.slots, hasLength(1));
      expect(harness.storage.rotation, isNull);
    });

    test('crash after database commit promotes the prepared candidate', () {
      final VaultHarness harness = _prepared();
      harness.machine.dispatch(const CommitDatabaseRotation());
      final String newKeyId = harness.storage.database!.keyId;

      harness.restart();
      harness.machine.dispatch(const RecoverRotation());

      expect(harness.machine.state, isA<VaultLocked>());
      expect(harness.storage.database!.keyId, newKeyId);
      expect(harness.storage.slots.values.single.keyId, newKeyId);
      expect(harness.storage.rotation, isNull);
    });

    test('crash after vault-pointer commit cleans the old slot', () {
      final VaultHarness harness = _prepared();
      harness.machine
        ..dispatch(const CommitDatabaseRotation())
        ..dispatch(const CommitVaultRotation());
      final String newKeyId = harness.storage.database!.keyId;

      harness.restart();
      harness.machine.dispatch(const RecoverRotation());

      expect(harness.machine.state, isA<VaultLocked>());
      expect(harness.storage.activeSlot, VaultSlot.b);
      expect(harness.storage.slots.values.single.keyId, newKeyId);
      expect(harness.storage.rotation, isNull);
    });

    test('ambiguous rotation metadata fails closed', () {
      final VaultHarness harness = _prepared();
      harness.storage.database = harness.storage.database!.copyWith(
        keyId: 'neither-slot',
      );

      harness.restart();
      expectRecovery(
        harness.machine.dispatch(const RecoverRotation()),
        VaultRecoveryReason.rotationMetadataMismatch,
      );
      expect(harness.storage.slots, hasLength(2));
      expect(harness.storage.rotation, isNotNull);
    });
  });

  group('explicit deletion', () {
    test('request and wrong confirmation never destroy ciphertext', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();

      expect(
        harness.machine.dispatch(const RequestDeletion()),
        isA<VaultStateChanged>(),
      );
      final VaultDeleting deleting = harness.machine.state as VaultDeleting;
      expect(harness.storage.database, isNotNull);
      expect(harness.storage.deletionMarker, isTrue);
      expect(
        harness.machine.dispatch(const ConfirmDeletion('wrong')),
        isA<VaultRejected>(),
      );
      expect(harness.storage.database, isNotNull);
      expect(deleting.confirmationToken, startsWith('DELETE:'));
    });

    test('matching confirmation deletes database and all slots', () {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      harness.machine.dispatch(const RequestDeletion());
      final String token =
          (harness.machine.state as VaultDeleting).confirmationToken;

      expect(
        harness.machine.dispatch(ConfirmDeletion(token)),
        isA<VaultDeletionCompleted>(),
      );
      expect(harness.machine.state, isA<VaultDeleted>());
      expect(harness.storage.database, isNull);
      expect(harness.storage.slots, isEmpty);
      expect(harness.storage.activeSlot, isNull);
    });
  });

  group('MachineBackedKeyVault adapter', () {
    test('release only succeeds while available and copies bytes', () async {
      final VaultHarness harness = VaultHarness.pin()..createPin();
      final MachineBackedKeyVault vault = MachineBackedKeyVault(
        harness.machine,
      );

      expect(vault.state, KeyVaultState.available);
      expect(vault.encryptedStoreExists, isTrue);

      final KeyLease lease = await vault.release();
      expect(lease.copyBytes(), isNotEmpty);
      await lease.dispose();
      expect(lease.isDisposed, isTrue);
      expect(lease.copyBytes, throwsStateError);
    });

    test(
      'release throws when locked so ciphertext routes to recovery',
      () async {
        final VaultHarness harness = VaultHarness.pin()..createPin();
        harness.machine.dispatch(const LockVault());
        final MachineBackedKeyVault vault = MachineBackedKeyVault(
          harness.machine,
        );

        expect(vault.state, KeyVaultState.locked);
        expect(vault.encryptedStoreExists, isTrue);
        await expectLater(
          vault.release(),
          throwsA(isA<KeyReleaseUnavailable>()),
        );
      },
    );

    test('fresh absent vault reports no encrypted store', () async {
      final VaultHarness harness = VaultHarness.pin();
      final MachineBackedKeyVault vault = MachineBackedKeyVault(
        harness.machine,
      );

      expect(vault.state, KeyVaultState.absent);
      expect(vault.encryptedStoreExists, isFalse);
      await expectLater(vault.release(), throwsA(isA<KeyReleaseUnavailable>()));
    });
  });
}

VaultHarness _prepared() {
  final VaultHarness harness = VaultHarness.pin()..createPin();
  expect(
    harness.machine.dispatch(const StartRotation(passphrase: '1234')),
    isA<VaultStateChanged>(),
  );
  expect(
    harness.machine.dispatch(const PrepareRotation()),
    isA<VaultStateChanged>(),
  );
  return harness;
}

SecureMaterial _withVaultId(SecureMaterial material, String vaultId) {
  return SecureMaterial(
    vaultVersion: material.vaultVersion,
    databaseVersion: material.databaseVersion,
    keyVersion: material.keyVersion,
    generationVersion: material.generationVersion,
    vaultId: vaultId,
    databaseId: material.databaseId,
    keyId: material.keyId,
    generation: material.generation,
    bindings: material.bindings,
    protection: material.protection,
    wrappedKey: material.wrappedKey,
    parameters: material.parameters,
  );
}

typedef _Mutation = VaultDatabaseMetadata Function(VaultDatabaseMetadata value);

final class _MismatchCase {
  const _MismatchCase(this.name, this.reason, this.mutate);
  final String name;
  final VaultRecoveryReason reason;
  final _Mutation mutate;
}
