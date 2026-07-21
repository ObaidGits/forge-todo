/// Independent security conformance harness — sync auth (task 12.4).
///
/// Verifies the redirect-auth security primitives end-to-end: PKCE S256
/// binding (a tampered verifier never satisfies the challenge), the one-use
/// callback guard (a replayed callback is rejected), atomic refresh replacement
/// (the client never holds two valid refresh tokens; only one concurrent
/// rotation wins), account-swap rejection, and secret redaction.
///
/// **Validates: Requirements R-SEC-002, R-SEC-004**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';

import '../helpers/evidence.dart';
import '../helpers/fake_auth_ports.dart';
import 'security_conformance_support.dart';

AuthTokens _tokens({
  required String access,
  required String refresh,
  int generation = 0,
  int expiresAtMicros = 1000000,
}) => AuthTokens(
  accessToken: SecretString(access),
  refreshToken: SecretString(refresh),
  tokenType: 'bearer',
  accessTokenExpiresAtUtcMicros: expiresAtMicros,
  accountFingerprint: AccountFingerprint('account-1'),
  rotationGeneration: generation,
);

void main() {
  group('PKCE S256 binding', () {
    final PkceFactory factory = PkceFactory(
      random: FakeSecureRandomSource(),
      hasher: const RealSha256Hasher(),
    );

    testWithEvidence(
      secEvidence('AUTH-PKCE-VERIFY', <String>['R-SEC-002']),
      'a freshly created S256 pair verifies and only issues S256',
      () {
        final PkcePair pair = factory.createS256();
        expect(pair.challenge.method, PkceChallengeMethod.s256);
        expect(factory.verify(pair.verifier, pair.challenge), isTrue);
      },
    );

    testWithEvidence(
      secEvidence('AUTH-PKCE-TAMPER', <String>['R-SEC-002']),
      'a different verifier never satisfies a challenge',
      () {
        final PkcePair a = factory.createS256();
        final PkcePair b = factory.createS256();
        expect(factory.verify(b.verifier, a.challenge), isFalse);
      },
    );
  });

  group('One-use callback guard', () {
    testWithEvidence(
      secEvidence('AUTH-CALLBACK-ONE-USE', <String>['R-SEC-002']),
      'a callback receipt is consumable exactly once (replay rejected)',
      () {
        final OneUseCallbackGuard guard = OneUseCallbackGuard();
        expect(guard.consume('req-1'), isTrue);
        expect(guard.consume('req-1'), isFalse);
        expect(guard.isConsumed('req-1'), isTrue);
      },
    );
  });

  group('Atomic refresh replacement', () {
    testWithEvidence(
      secEvidence('AUTH-ATOMIC-REFRESH', <String>['R-SEC-002']),
      'exactly one of two concurrent rotations at the same generation persists',
      () async {
        final InMemorySecureTokenStore store = InMemorySecureTokenStore();
        await store.compareAndSwapTokens(
          expectedGeneration: kNoStoredTokensGeneration,
          next: _tokens(access: 'a0', refresh: 'r0'),
        );
        final AuthTokens current = (await store.readTokens())!;
        final AuthTokens rotationA = current.rotate(
          newAccessToken: SecretString('aA'),
          newRefreshToken: SecretString('rA'),
          newAccessTokenExpiresAtUtcMicros: 2000000,
          responseFingerprint: current.accountFingerprint,
        );
        final AuthTokens rotationB = current.rotate(
          newAccessToken: SecretString('aB'),
          newRefreshToken: SecretString('rB'),
          newAccessTokenExpiresAtUtcMicros: 2000000,
          responseFingerprint: current.accountFingerprint,
        );
        final bool wonA = await store.compareAndSwapTokens(
          expectedGeneration: current.rotationGeneration,
          next: rotationA,
        );
        final bool wonB = await store.compareAndSwapTokens(
          expectedGeneration: current.rotationGeneration,
          next: rotationB,
        );
        expect(wonA, isTrue);
        expect(wonB, isFalse);
        // Exactly one stored token set survives — never two valid refreshes.
        final AuthTokens stored = (await store.readTokens())!;
        expect(stored.rotationGeneration, current.rotationGeneration + 1);
        expect(stored.refreshToken.reveal(), 'rA');
      },
    );

    testWithEvidence(
      secEvidence('AUTH-ACCOUNT-SWAP', <String>['R-SEC-002']),
      'a rotation whose account fingerprint differs is refused',
      () {
        final AuthTokens current = _tokens(access: 'a0', refresh: 'r0');
        expect(
          () => current.rotate(
            newAccessToken: SecretString('aX'),
            newRefreshToken: SecretString('rX'),
            newAccessTokenExpiresAtUtcMicros: 2000000,
            responseFingerprint: AccountFingerprint('other-account'),
          ),
          throwsA(isA<AccountMismatchException>()),
        );
      },
    );
  });

  group('Secret redaction', () {
    testWithEvidence(
      secEvidence('AUTH-SECRET-REDACTED', <String>['R-SEC-004']),
      'tokens, state, nonce, and secret wrappers never render their value',
      () {
        final AuthTokens tokens = _tokens(access: 'access-xyz', refresh: 'r0');
        expect(tokens.toString(), isNot(contains('access-xyz')));
        expect(const SecretString('top-secret').toString(), '[redacted]');
        expect(
          const OAuthState(SecretString('state-val')).toString(),
          isNot(contains('state-val')),
        );
        expect(
          const OAuthNonce(SecretString('nonce-val')).toString(),
          isNot(contains('nonce-val')),
        );
      },
    );
  });
}
