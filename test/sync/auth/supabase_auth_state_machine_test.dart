/// The Supabase redirect-auth state machine: full flow, verification failures,
/// atomic refresh, account-swap, revocation, sign-out, remote-delete reauth,
/// and restart restore (R-SYNC-001, R-SYNC-008, R-SEC-002; design.md §13,
/// data-model.md §6).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/application/auth/supabase_auth_state_machine.dart';
import 'package:forge/features/sync/domain/auth/auth_status.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

import '../../helpers/evidence.dart';
import '../../helpers/fake_auth_ports.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-001'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-AUTH-MACHINE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.4'),
  requirements: requirements.map(RequirementId.new).toList(),
);

const String _redirect = 'forge://auth/callback';

final class _Harness {
  _Harness({bool initiallyLinked = false})
    : clock = FakeClock(initialUtc: DateTime.utc(2024, 1, 1)),
      store = InMemorySecureTokenStore(),
      gateway = FakeOAuthGateway(
        accountFingerprint: AccountFingerprint('acct-1'),
      ) {
    machine = SupabaseAuthStateMachine(
      clock: clock,
      ids: FakeIdGenerator.sequential(),
      pkce: PkceFactory(
        random: FakeSecureRandomSource(),
        hasher: const RealSha256Hasher(),
      ),
      antiForgery: AntiForgeryFactory(FakeSecureRandomSource(seed: 99)),
      gateway: gateway,
      store: store,
      deviceId: DeviceId('device-1'),
      config: AuthFlowConfig(
        redirectUri: _redirect,
        allowlist: RedirectUriAllowlist(const <String>[_redirect]),
      ),
      initiallyLinked: initiallyLinked,
    );
  }

  final FakeClock clock;
  final InMemorySecureTokenStore store;
  final FakeOAuthGateway gateway;
  late final SupabaseAuthStateMachine machine;

  /// Runs a successful authorization and returns the resulting status.
  Future<AuthStatus> authenticate({String code = 'auth-code'}) async {
    final AuthorizationRequest request =
        (await machine.beginAuthorization()).valueOrNull!;
    gateway.nextNonce = request.nonce.value.reveal();
    final Result<AuthStatus> result = await machine.handleCallback(
      '$_redirect?code=$code&state=${request.state.value.reveal()}',
    );
    return result.valueOrNull!;
  }
}

void main() {
  group('Authorization request', () {
    testWithEvidence(
      _evidence('BEGIN-ISSUES-PKCE-STATE-NONCE'),
      'beginAuthorization issues an S256 challenge, persists pending, and enters '
      'authenticating',
      () async {
        final _Harness h = _Harness();
        final Result<AuthorizationRequest> result = await h.machine
            .beginAuthorization();
        final AuthorizationRequest request = result.valueOrNull!;
        expect(request.codeChallengeMethod, 'S256');
        expect(request.redirectUri, _redirect);
        expect(request.responseType, 'code');
        expect(h.machine.syncLinkState, SyncLinkState.authenticating);
        // Pending is persisted to secure storage (survives restart).
        expect(await h.store.readPendingAuthorization(), isNotNull);
        // Nothing is written to the token store yet.
        expect(await h.store.readTokens(), isNull);
      },
    );
  });

  group('Callback verification', () {
    testWithEvidence(
      _evidence('HAPPY-PATH-AUTHENTICATES'),
      'a valid callback exchanges the code and stores a token session',
      () async {
        final _Harness h = _Harness();
        final AuthStatus status = await h.authenticate();
        expect(status.phase, AuthPhase.authenticated);
        // No link yet -> link preview (task 9.5 completes linking).
        expect(status.syncLinkState, SyncLinkState.linkPreview);
        final AuthTokens? tokens = await h.store.readTokens();
        expect(tokens, isNotNull);
        expect(tokens!.rotationGeneration, 0);
        expect(h.gateway.exchangeCalls, 1);
      },
    );

    testWithEvidence(
      _evidence('LINKED-WHEN-BOUND'),
      'an authenticated session with an existing link projects to linked',
      () async {
        final _Harness h = _Harness(initiallyLinked: true);
        final AuthStatus status = await h.authenticate();
        expect(status.syncLinkState, SyncLinkState.linked);
      },
    );

    testWithEvidence(
      _evidence('REPLAY-REJECTED'),
      'delivering the same callback twice is rejected the second time',
      () async {
        final _Harness h = _Harness();
        final AuthorizationRequest request =
            (await h.machine.beginAuthorization()).valueOrNull!;
        h.gateway.nextNonce = request.nonce.value.reveal();
        final String url =
            '$_redirect?code=c&state=${request.state.value.reveal()}';
        final Result<AuthStatus> first = await h.machine.handleCallback(url);
        expect(first, isA<Success<AuthStatus>>());
        final Result<AuthStatus> second = await h.machine.handleCallback(url);
        expect(second, isA<Failed<AuthStatus>>());
        // The code was exchanged exactly once.
        expect(h.gateway.exchangeCalls, 1);
      },
    );

    testWithEvidence(
      _evidence('STATE-MISMATCH-REJECTED'),
      'a callback whose state does not match the pending request is rejected',
      () async {
        final _Harness h = _Harness();
        final AuthorizationRequest request =
            (await h.machine.beginAuthorization()).valueOrNull!;
        h.gateway.nextNonce = request.nonce.value.reveal();
        final Result<AuthStatus> result = await h.machine.handleCallback(
          '$_redirect?code=c&state=forged-state',
        );
        expect(result.failureOrNull!.code, 'sync.auth.stateMismatch');
        expect(h.gateway.exchangeCalls, 0);
        expect(await h.store.readTokens(), isNull);
      },
    );

    testWithEvidence(
      _evidence('NONCE-MISMATCH-REJECTED'),
      'a token whose nonce does not match the request stores no session',
      () async {
        final _Harness h = _Harness();
        final AuthorizationRequest request =
            (await h.machine.beginAuthorization()).valueOrNull!;
        h.gateway.nextNonce = 'wrong-nonce';
        final Result<AuthStatus> result = await h.machine.handleCallback(
          '$_redirect?code=c&state=${request.state.value.reveal()}',
        );
        expect(result.failureOrNull!.code, 'sync.auth.nonceMismatch');
        expect(await h.store.readTokens(), isNull);
      },
    );

    testWithEvidence(
      _evidence('REDIRECT-NOT-ALLOWED-REJECTED'),
      'a callback on an unregistered redirect is rejected before anything else',
      () async {
        final _Harness h = _Harness();
        await h.machine.beginAuthorization();
        final Result<AuthStatus> result = await h.machine.handleCallback(
          'forge://evil/callback?code=c&state=s',
        );
        expect(result.failureOrNull!.code, 'sync.auth.redirectNotAllowed');
        expect(h.gateway.exchangeCalls, 0);
      },
    );

    testWithEvidence(
      _evidence('PROVIDER-ERROR-REJECTED'),
      'a provider error parameter is surfaced and no exchange occurs',
      () async {
        final _Harness h = _Harness();
        final AuthorizationRequest request =
            (await h.machine.beginAuthorization()).valueOrNull!;
        final Result<AuthStatus> result = await h.machine.handleCallback(
          '$_redirect?error=access_denied&state=${request.state.value.reveal()}',
        );
        expect(result.failureOrNull!.code, 'sync.auth.providerError');
        expect(h.gateway.exchangeCalls, 0);
      },
    );
  });

  group('Refresh', () {
    testWithEvidence(
      _evidence(
        'ATOMIC-ROTATION',
        requirements: <String>['R-SYNC-001', 'R-SEC-002'],
      ),
      'refresh rotates to a new generation and keeps a single stored token set',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        final AuthTokens before = (await h.store.readTokens())!;
        final Result<AuthStatus> result = await h.machine.refreshSession();
        expect(result, isA<Success<AuthStatus>>());
        final AuthTokens after = (await h.store.readTokens())!;
        expect(after.rotationGeneration, before.rotationGeneration + 1);
        expect(after.refreshToken, isNot(before.refreshToken));
        expect(h.machine.status.phase, AuthPhase.authenticated);
      },
    );

    testWithEvidence(
      _evidence('INVALID-GRANT-EXPIRES'),
      'an invalid refresh grant transitions to expired',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        h.gateway.refreshError = const OAuthGatewayException(
          OAuthGatewayErrorKind.invalidGrant,
        );
        final Result<AuthStatus> result = await h.machine.refreshSession();
        expect(result, isA<Failed<AuthStatus>>());
        expect(h.machine.syncLinkState, SyncLinkState.expired);
      },
    );

    testWithEvidence(
      _evidence('REVOKED-DEVICE-CLEARS-TOKENS'),
      'a revoked device clears tokens and requires reauthentication',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        h.gateway.refreshError = const OAuthGatewayException(
          OAuthGatewayErrorKind.revokedDevice,
        );
        await h.machine.refreshSession();
        expect(h.machine.syncLinkState, SyncLinkState.revoked);
        expect(await h.store.readTokens(), isNull);
      },
    );

    testWithEvidence(
      _evidence('NETWORK-ERROR-RETRYABLE'),
      'a network refresh error is retryable and preserves the session',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        h.gateway.refreshError = const OAuthGatewayException(
          OAuthGatewayErrorKind.network,
        );
        final Result<AuthStatus> result = await h.machine.refreshSession();
        expect(result.failureOrNull!.retryable, isTrue);
        // Tokens are untouched by a transient failure.
        expect(await h.store.readTokens(), isNotNull);
      },
    );
  });

  group('Account swap', () {
    testWithEvidence(
      _evidence('CALLBACK-DIFFERENT-ACCOUNT'),
      'authenticating a different account than the stored one is account_changed',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        // A new sign-in for a different account.
        h.gateway.accountFingerprint = AccountFingerprint('acct-2');
        final AuthStatus status = await h.authenticate(code: 'code-2');
        expect(status.syncLinkState, SyncLinkState.accountChanged);
        // The previous account's tokens are not overwritten.
        expect(
          (await h.store.readTokens())!.accountFingerprint.value,
          'acct-1',
        );
      },
    );

    testWithEvidence(
      _evidence('REFRESH-DIFFERENT-ACCOUNT'),
      'a refresh returning a different account is account_changed',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        h.gateway.refreshFingerprintOverride = AccountFingerprint('acct-2');
        final Result<AuthStatus> result = await h.machine.refreshSession();
        expect(result.valueOrNull!.syncLinkState, SyncLinkState.accountChanged);
      },
    );
  });

  group('Revocation and sign-out', () {
    testWithEvidence(
      _evidence('HANDLE-REVOCATION'),
      'a server revocation signal clears tokens and enters revoked',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        await h.machine.handleRevocation();
        expect(h.machine.syncLinkState, SyncLinkState.revoked);
        expect(await h.store.readTokens(), isNull);
      },
    );

    testWithEvidence(
      _evidence('SIGN-OUT-RETAINS-LOCAL', requirements: <String>['R-SYNC-008']),
      'sign-out revokes server-side, clears tokens, and reports the retain '
      'choice',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        final Result<bool> result = await h.machine.signOut(
          retainLocalData: true,
        );
        expect(result.valueOrNull, isTrue);
        expect(h.gateway.revokeCalls, 1);
        expect(await h.store.readTokens(), isNull);
        expect(h.machine.syncLinkState, SyncLinkState.signedOut);
      },
    );
  });

  group('Remote delete reauthentication', () {
    testWithEvidence(
      _evidence('REQUIRES-RECENT-REAUTH', requirements: <String>['R-SYNC-008']),
      'remote delete requires a recent reauthentication window',
      () async {
        final _Harness h = _Harness(initiallyLinked: true);
        await h.authenticate();
        h.machine.requireRemoteDeleteReauth();
        expect(h.machine.syncLinkState, SyncLinkState.remoteDeleteReauth);
        // Reauthenticate now.
        await h.authenticate(code: 'reauth-code');
        expect(h.machine.hasRecentReauthentication, isTrue);
        // After the window elapses, recent reauthentication no longer holds.
        h.clock.advance(const Duration(minutes: 10));
        expect(h.machine.hasRecentReauthentication, isFalse);
      },
    );
  });

  group('Restore after restart', () {
    testWithEvidence(
      _evidence('RESTORE-VALID-SESSION', requirements: <String>['R-SEC-002']),
      'valid stored tokens restore an authenticated session',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        // Simulate a fresh machine over the same secure store.
        final SupabaseAuthStateMachine reopened = SupabaseAuthStateMachine(
          clock: h.clock,
          ids: FakeIdGenerator.sequential(),
          pkce: PkceFactory(
            random: FakeSecureRandomSource(),
            hasher: const RealSha256Hasher(),
          ),
          antiForgery: AntiForgeryFactory(FakeSecureRandomSource()),
          gateway: h.gateway,
          store: h.store,
          deviceId: DeviceId('device-1'),
          config: AuthFlowConfig(
            redirectUri: _redirect,
            allowlist: RedirectUriAllowlist(const <String>[_redirect]),
          ),
        );
        final AuthStatus status = await reopened.restore();
        expect(status.phase, AuthPhase.authenticated);
      },
    );

    testWithEvidence(
      _evidence('RESTORE-EXPIRED-SESSION', requirements: <String>['R-SEC-002']),
      'stored-but-expired tokens restore the expired state',
      () async {
        final _Harness h = _Harness();
        await h.authenticate();
        // Advance well past the access-token expiry.
        h.clock.advance(const Duration(hours: 2));
        final AuthStatus status = await h.machine.restore();
        expect(status.phase, AuthPhase.expired);
      },
    );

    testWithEvidence(
      _evidence('RESTORE-SIGNED-OUT', requirements: <String>['R-SEC-002']),
      'no stored tokens restore the signed-out state',
      () async {
        final _Harness h = _Harness();
        final AuthStatus status = await h.machine.restore();
        expect(status.phase, AuthPhase.signedOut);
      },
    );
  });
}
