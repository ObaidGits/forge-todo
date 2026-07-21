/// Independent security conformance harness — key lifecycle & log redaction
/// (task 12.4).
///
/// Verifies the KeyVault fail-closed spine end-to-end (create → lock → unlock →
/// rotate → delete), the non-negotiable invariant that existing ciphertext can
/// never mint a replacement key, headless skip when user presence is required,
/// and that no key material or sensitive value survives structured logging
/// (R-SEC-004).
///
/// **Validates: Requirements R-SEC-001, R-SEC-002, R-SEC-003, R-SEC-004**
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/key_vault_machine.dart';
import 'package:forge/core/security/key_vault_ports.dart';
import 'package:forge/core/security/redacting_log.dart';

import '../helpers/evidence.dart';
import 'security_conformance_support.dart';

void main() {
  group('KeyVault lifecycle spine', () {
    testWithEvidence(
      secEvidence('KEY-FULL-LIFECYCLE', <String>['R-SEC-001', 'R-SEC-002']),
      'create, lock, unlock, rotate, and delete traverse the fail-closed states',
      () {
        final VaultConformanceHarness h = VaultConformanceHarness.pin();
        expect(
          h.machine.dispatch(
            const CreateVault(
              databaseId: 'db-1',
              protection: VaultProtection.pinFallback,
              passphrase: '1234',
            ),
          ),
          isA<VaultKeyReleased>(),
        );
        expect(h.machine.dispatch(const LockVault()), isA<VaultStateChanged>());
        expect(h.machine.state, isA<VaultLocked>());
        expect(
          h.machine.dispatch(const UnlockWithPassphrase('1234')),
          isA<VaultKeyReleased>(),
        );
        // Crash-safe two-slot rotation.
        h.machine.dispatch(const StartRotation(passphrase: '1234'));
        h.machine.dispatch(const PrepareRotation());
        h.machine.dispatch(const CommitDatabaseRotation());
        h.machine.dispatch(const CommitVaultRotation());
        expect(
          h.machine.dispatch(const CompleteRotation()),
          isA<VaultKeyReleased>(),
        );
        // Explicit deletion requires the confirmation token.
        final VaultActionResult requested = h.machine.dispatch(
          const RequestDeletion(),
        );
        expect(requested, isA<VaultStateChanged>());
        final VaultDeleting deleting = h.machine.state as VaultDeleting;
        expect(
          h.machine.dispatch(ConfirmDeletion(deleting.confirmationToken)),
          isA<VaultDeletionCompleted>(),
        );
        expect(h.machine.state, isA<VaultDeleted>());
      },
    );

    testWithEvidence(
      secEvidence('KEY-NO-REPLACEMENT', <String>['R-SEC-001', 'R-SEC-002']),
      'existing ciphertext whose secure material is gone enters Recovery, '
      'never a replacement key',
      () {
        final VaultConformanceHarness h = VaultConformanceHarness.pin();
        h.machine.dispatch(
          const CreateVault(
            databaseId: 'db-1',
            protection: VaultProtection.pinFallback,
            passphrase: '1234',
          ),
        );
        // Simulate a secure-store reset / reinstall: the database identity
        // remains but the wrapped material is gone.
        h.storage.removeSlot(VaultSlot.a);
        h.storage.activeSlot = null;
        final VaultActionResult booted = h.restart();
        expect(booted, isA<VaultRecoveryEntered>());
        expect(h.machine.state, isA<VaultRecoveryRequired>());
        // A create is refused because the install is not provably fresh.
        expect(
          h.machine.dispatch(
            const CreateVault(
              databaseId: 'db-1',
              protection: VaultProtection.pinFallback,
              passphrase: 'new',
            ),
          ),
          isA<VaultRejected>(),
        );
      },
    );

    testWithEvidence(
      secEvidence('KEY-UNSUPPORTED-NO-PLAINTEXT', <String>['R-SEC-002']),
      'a platform with neither secure store nor fallback is unsupported, '
      'never plaintext',
      () {
        final VaultConformanceHarness h = VaultConformanceHarness.unsupported();
        final VaultActionResult result = h.machine.dispatch(
          const CreateVault(
            databaseId: 'db-1',
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
      },
    );

    testWithEvidence(
      secEvidence('KEY-HEADLESS-SKIP', <String>['R-SEC-001', 'R-SEC-003']),
      'headless release skips safely when the protection needs user presence',
      () {
        final VaultConformanceHarness h = VaultConformanceHarness.pin();
        h.machine.dispatch(
          const CreateVault(
            databaseId: 'db-1',
            protection: VaultProtection.pinFallback,
            passphrase: '1234',
          ),
        );
        h.machine.dispatch(const LockVault());
        expect(
          h.machine.dispatch(const HeadlessRelease()),
          isA<VaultHeadlessSkipped>(),
        );
      },
    );

    testWithEvidence(
      secEvidence('KEY-DEVICE-HEADLESS-OK', <String>['R-SEC-003']),
      'a device secure-store key releases headless without user presence',
      () {
        final VaultConformanceHarness h = VaultConformanceHarness.device();
        h.machine.dispatch(
          const CreateVault(
            databaseId: 'db-1',
            protection: VaultProtection.deviceSecureStore,
          ),
        );
        h.machine.dispatch(const LockVault());
        expect(
          h.machine.dispatch(const HeadlessRelease()),
          isA<VaultKeyReleased>(),
        );
      },
    );
  });

  group('Log redaction (no key material or secrets in logs)', () {
    final DateTime now = DateTime.utc(2026, 2, 3, 4, 5, 6);

    StructuredLogger logger(LocalLogBuffer buffer) => StructuredLogger(
      utcNow: () => now,
      sinks: <LocalLogSink>[buffer],
      minimumLevel: LogLevel.debug,
    );

    testWithEvidence(
      secEvidence('LOG-REDACTS-SECRETS', <String>['R-SEC-004']),
      'content, tokens, secret URLs, external paths, and ids are all redacted',
      () {
        final LocalLogBuffer buffer = LocalLogBuffer();
        logger(buffer).log(
          level: LogLevel.warning,
          component: 'security',
          eventCode: 'vault.release',
          attributes: <String, LogAttribute>{
            'duration_ms': const LogAttribute.operational(7),
            'phase': const LogAttribute.operational('available'),
            'wrapped_key': const LogAttribute.credential('pin-envelope-1'),
            'access_token': const LogAttribute.credential(
              'Bearer abc.def.ghijk',
            ),
            'reset_url': const LogAttribute.secretUrl(
              'https://acct.test/reset?token=deadbeef',
            ),
            'db_path': const LogAttribute.externalPath('/home/p/forge.db'),
            'profile_id': const LogAttribute.operational(
              '01890f3e-7b8a-7cc2-8b34-123456789abc',
            ),
          },
        );
        final StructuredLogRecord record = buffer.records.single;
        expect(record.attributes['duration_ms'], 7);
        expect(record.attributes['phase'], 'available');
        for (final String key in <String>[
          'wrapped_key',
          'access_token',
          'reset_url',
          'db_path',
          'profile_id',
        ]) {
          expect(
            record.attributes[key],
            LogRedactor.redactedValue,
            reason: '$key must be redacted',
          );
        }
        final String encoded = jsonEncode(record.toJson());
        expect(encoded, isNot(contains('deadbeef')));
        expect(encoded, isNot(contains('forge.db')));
        expect(encoded, isNot(contains('01890f3e')));
      },
    );
  });
}
