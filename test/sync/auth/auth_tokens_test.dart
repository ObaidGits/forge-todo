/// Auth token rotation, account-swap detection, redaction, and the atomic
/// refresh-replacement invariant (R-SYNC-001 "atomic refresh replacement",
/// R-SEC-002; design.md §13).
///
/// The key safety property: the client never holds two valid refresh tokens.
/// Rotation produces a single successor with a strictly higher generation, and
/// the store's compare-and-swap on that generation lets exactly one of any set
/// of concurrent rotations win.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';

import '../../helpers/evidence.dart';
import '../../helpers/fake_auth_ports.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-001'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-AUTH-TOKENS-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.4'),
  requirements: requirements.map(RequirementId.new).toList(),
);

AuthTokens _tokens({int generation = 0, String account = 'acct-1'}) =>
    AuthTokens(
      accessToken: SecretString('access-$generation'),
      refreshToken: SecretString('refresh-$generation'),
      tokenType: 'bearer',
      accessTokenExpiresAtUtcMicros: 1000000,
      accountFingerprint: AccountFingerprint(account),
      rotationGeneration: generation,
    );

void main() {
  group('AuthTokens rotation', () {
    testWithEvidence(
      _evidence('ROTATE-INCREMENTS-GENERATION'),
      'rotation replaces both tokens and strictly increases the generation',
      () {
        final AuthTokens initial = _tokens();
        final AuthTokens rotated = initial.rotate(
          newAccessToken: const SecretString('access-new'),
          newRefreshToken: const SecretString('refresh-new'),
          newAccessTokenExpiresAtUtcMicros: 2000000,
          responseFingerprint: AccountFingerprint('acct-1'),
        );
        expect(rotated.rotationGeneration, initial.rotationGeneration + 1);
        expect(rotated.refreshToken.reveal(), 'refresh-new');
        expect(rotated.refreshToken, isNot(initial.refreshToken));
      },
    );

    testWithEvidence(
      _evidence('ROTATE-REJECTS-ACCOUNT-SWAP'),
      'rotating into a different account throws rather than taking over',
      () {
        final AuthTokens initial = _tokens();
        expect(
          () => initial.rotate(
            newAccessToken: const SecretString('access-new'),
            newRefreshToken: const SecretString('refresh-new'),
            newAccessTokenExpiresAtUtcMicros: 2000000,
            responseFingerprint: AccountFingerprint('acct-2'),
          ),
          throwsA(isA<AccountMismatchException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('ACCESS-TOKEN-VALIDITY-SKEW'),
      'validity honors a refresh skew so tokens refresh before hard expiry',
      () {
        final AuthTokens tokens = _tokens();
        // Well before expiry: valid.
        expect(tokens.accessTokenValid(0), isTrue);
        // Within skew of expiry: treated as invalid to force early refresh.
        expect(
          tokens.accessTokenValid(999000, skew: const Duration(seconds: 1)),
          isFalse,
        );
      },
    );

    testWithEvidence(
      _evidence('SECRET-REDACTION'),
      'tokens never render secret material through toString',
      () {
        final AuthTokens tokens = _tokens();
        expect(tokens.toString().contains('refresh-0'), isFalse);
        expect(tokens.accessToken.toString(), '[redacted]');
      },
    );
  });

  group('Atomic refresh replacement', () {
    testWithEvidence(
      _evidence(
        'CONCURRENT-ROTATION-SINGLE-WINNER',
        requirements: <String>['R-SYNC-001', 'R-SEC-002'],
      ),
      'exactly one of many concurrent rotations at the same generation persists',
      () async {
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          final InMemorySecureTokenStore store = InMemorySecureTokenStore();
          // Seed the store with an initial session (first write).
          await store.compareAndSwapTokens(
            expectedGeneration: kNoStoredTokensGeneration,
            next: _tokens(),
          );

          // Several "concurrent" refreshers all read the same generation and
          // try to swap in their own successor.
          final AuthTokens current = (await store.readTokens())!;
          final int racers = 2 + rng.nextInt(4);
          int successes = 0;
          for (int r = 0; r < racers; r += 1) {
            final AuthTokens candidate = current.rotate(
              newAccessToken: SecretString('access-r$r'),
              newRefreshToken: SecretString('refresh-r$r'),
              newAccessTokenExpiresAtUtcMicros: 2000000 + r,
              responseFingerprint: current.accountFingerprint,
            );
            final bool ok = await store.compareAndSwapTokens(
              expectedGeneration: current.rotationGeneration,
              next: candidate,
            );
            if (ok) {
              successes += 1;
            }
          }

          // Exactly one racer won: no window with two valid refresh tokens.
          expect(successes, 1, reason: 'multiple winners for seed=$seed');
          final AuthTokens after = (await store.readTokens())!;
          expect(after.rotationGeneration, current.rotationGeneration + 1);
        }
      },
    );

    testWithEvidence(
      _evidence('MONOTONIC-GENERATION-CHAIN'),
      'sequential rotations keep the store single-valued with a rising chain',
      () async {
        final InMemorySecureTokenStore store = InMemorySecureTokenStore();
        await store.compareAndSwapTokens(
          expectedGeneration: kNoStoredTokensGeneration,
          next: _tokens(),
        );
        int lastGeneration = 0;
        for (int i = 0; i < 25; i += 1) {
          final AuthTokens current = (await store.readTokens())!;
          expect(current.rotationGeneration, lastGeneration);
          final AuthTokens next = current.rotate(
            newAccessToken: SecretString('access-$i'),
            newRefreshToken: SecretString('refresh-$i'),
            newAccessTokenExpiresAtUtcMicros: 2000000 + i,
            responseFingerprint: current.accountFingerprint,
          );
          expect(
            await store.compareAndSwapTokens(
              expectedGeneration: current.rotationGeneration,
              next: next,
            ),
            isTrue,
          );
          lastGeneration += 1;
        }
        expect((await store.readTokens())!.rotationGeneration, 25);
      },
    );
  });
}
