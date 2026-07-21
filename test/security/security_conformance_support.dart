/// Shared construction for the independent, consolidated security conformance
/// harness (task 12.4).
///
/// This support library exists so the seven area suites in `test/security/`
/// are driven from ONE place and reuse the same fakes as the scattered
/// per-feature tests rather than forking new ones. It wires:
///
///   * the production [KeyVaultMachine] against the in-memory port fakes
///     (`fake_key_vault_ports.dart`);
///   * the FBC1 [Fbc1Codec] against the real-AEAD in-process backup crypto
///     (`backup_test_crypto.dart`);
///   * evidence metadata stamped for task 12.4.
///
/// Every check that needs a live Drift database or device is isolated to the
/// attachments suite (which reuses the existing `AttachmentHarness`); the RLS
/// live SQL path stays in `supabase/tests` and its in-repo automated gate is
/// `tool/sync_server_lint.py`, exercised by the Python conformance harness.
library;

import 'package:forge/core/security/key_vault_machine.dart';
import 'package:forge/core/security/key_vault_ports.dart';

import '../helpers/evidence.dart';
import '../helpers/fake_key_vault_ports.dart';

/// Builds task-12.4 evidence metadata with a stable `TEST-SECCONF-*` id.
EvidenceMetadata secEvidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('TEST-SECCONF-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('12.4'),
      requirements: requirements
          .map((String id) => RequirementId(id))
          .toList(growable: false),
    );

/// A restartable KeyVault harness that owns durable storage so a "process
/// restart" (rebuilding the machine over the same storage) re-runs boot
/// inspection. Mirrors the unit harness but lives here so the conformance
/// suite is self-contained.
final class VaultConformanceHarness {
  VaultConformanceHarness(this.environment) {
    machine = _build();
  }

  factory VaultConformanceHarness.pin() => VaultConformanceHarness(
    const VaultEnvironment(
      secureStoreAvailable: false,
      passphraseFallbackConfigured: true,
    ),
  );

  factory VaultConformanceHarness.device() => VaultConformanceHarness(
    const VaultEnvironment(
      secureStoreAvailable: true,
      passphraseFallbackConfigured: false,
    ),
  );

  factory VaultConformanceHarness.unsupported() => VaultConformanceHarness(
    const VaultEnvironment(
      secureStoreAvailable: false,
      passphraseFallbackConfigured: false,
    ),
  );

  VaultEnvironment environment;
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
  );

  /// Rebuilds the machine against the same storage (a simulated restart) and
  /// returns the boot inspection result.
  VaultActionResult restart() {
    machine = _build();
    return machine.dispatch(const InspectVault());
  }
}
