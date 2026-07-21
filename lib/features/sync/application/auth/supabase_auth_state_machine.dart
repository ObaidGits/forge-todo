/// The Supabase redirect-auth state machine (R-SYNC-001, R-SYNC-008,
/// R-SEC-002; design.md §13, data-model.md §6 "Bootstrap, relink, and auth").
///
/// It drives the sync link auth states (`signed_out`, `authenticating`,
/// `link_preview`/`linked`, `expired`, `revoked`, `account_changed`,
/// `remote_delete_reauth`) using PKCE, an anti-forgery `state`, an ID-token
/// `nonce`, an exact redirect allowlist, one-use callback receipts, and atomic
/// refresh-token replacement. The concrete Supabase client and platform secure
/// storage are behind ports; nothing here imports Supabase, Drift, or Flutter.
library;

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_status.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

/// Configuration for the redirect flow. The [redirectUri] must be one of the
/// [allowlist]'s exact entries; scopes are the OpenID scopes requested.
final class AuthFlowConfig {
  AuthFlowConfig({
    required this.redirectUri,
    required this.allowlist,
    this.scopes = const <String>['openid', 'offline_access'],
    this.accessTokenRefreshSkew = const Duration(seconds: 30),
    this.recentReauthWindow = const Duration(minutes: 5),
  }) {
    if (!allowlist.isAllowed(redirectUri)) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Configured redirect URI is not in the exact allowlist.',
      );
    }
  }

  final String redirectUri;
  final RedirectUriAllowlist allowlist;
  final List<String> scopes;
  final Duration accessTokenRefreshSkew;
  final Duration recentReauthWindow;
}

/// Orchestrates authentication against an [OAuthGateway] and [SecureTokenStore].
final class SupabaseAuthStateMachine {
  SupabaseAuthStateMachine({
    required this.clock,
    required this.ids,
    required this.pkce,
    required this.antiForgery,
    required this.gateway,
    required this.store,
    required this.deviceId,
    required this.config,
    bool initiallyLinked = false,
  }) : _hasLink = initiallyLinked;

  final Clock clock;
  final IdGenerator ids;
  final PkceFactory pkce;
  final AntiForgeryFactory antiForgery;
  final OAuthGateway gateway;
  final SecureTokenStore store;
  final DeviceId deviceId;
  final AuthFlowConfig config;

  AuthStatus _status = AuthStatus.signedOut();
  bool _hasLink;
  int? _lastAuthenticatedAtUtcMicros;

  AuthStatus get status => _status.copyWith(hasLink: _hasLink);

  /// The current link auth state (R-SYNC-001), used by the sync status surface.
  SyncLinkState get syncLinkState => status.syncLinkState;

  /// Records whether a durable profile link exists (task 9.5 owns linking).
  void bindLinked(bool value) => _hasLink = value;

  /// Rebuilds the in-memory phase from secure storage on startup. Tokens that
  /// are still valid restore an authenticated session; present-but-expired
  /// tokens restore `expired`; no tokens restores `signed_out`.
  Future<AuthStatus> restore() async {
    final AuthTokens? tokens = await store.readTokens();
    if (tokens == null) {
      _status = AuthStatus.signedOut();
      return status;
    }
    final bool valid = tokens.accessTokenValid(
      clock.utcNow().microsecondsSinceEpoch,
      skew: config.accessTokenRefreshSkew,
    );
    _status = AuthStatus(
      phase: valid ? AuthPhase.authenticated : AuthPhase.expired,
      hasLink: _hasLink,
      accountFingerprint: tokens.accountFingerprint,
    );
    return status;
  }

  /// Begins a redirect authorization request: mints PKCE/state/nonce, persists
  /// the pending request to secure storage (so a post-restart callback still
  /// verifies), and returns the authorize parameters. Phase → authenticating.
  Future<Result<AuthorizationRequest>> beginAuthorization({
    bool isReauthentication = false,
  }) async {
    final PkcePair pair = pkce.createS256();
    final OAuthState state = antiForgery.createState();
    final OAuthNonce nonce = antiForgery.createNonce();
    final PendingAuthorization pending = PendingAuthorization(
      requestId: ids.uuidV7(),
      pkce: pair,
      state: state,
      nonce: nonce,
      redirectUri: config.redirectUri,
      createdAtUtcMicros: clock.utcNow().microsecondsSinceEpoch,
      isReauthentication: isReauthentication,
    );
    await store.writePendingAuthorization(pending);
    _status = _status.copyWith(phase: AuthPhase.authenticating);
    return Success<AuthorizationRequest>(
      AuthorizationRequest(
        responseType: 'code',
        redirectUri: config.redirectUri,
        codeChallenge: pair.challenge.value,
        codeChallengeMethod: pair.challenge.method.wireName,
        state: state,
        nonce: nonce,
        scopes: config.scopes,
      ),
    );
  }

  /// Verifies and completes a redirect callback: exact redirect match, `state`
  /// match, one-use consumption, PKCE code exchange, `nonce` match, and
  /// account-swap detection. On success it atomically stores the token session.
  Future<Result<AuthStatus>> handleCallback(String rawCallback) async {
    final AuthCallback callback = AuthCallback.parse(rawCallback);

    // Exact redirect allowlist match precedes everything else.
    if (!config.allowlist.isAllowed(callback.redirectUri)) {
      return _rejected(AuthFlowRejection.redirectNotAllowed);
    }

    final PendingAuthorization? pending = await store
        .readPendingAuthorization();
    if (pending == null) {
      return _rejected(AuthFlowRejection.noPendingAuthorization);
    }

    // Replay guard: a receipt (keyed by the pending request id) is one-use.
    final Set<String> consumed = await store.readConsumedReceipts();
    if (consumed.contains(pending.requestId)) {
      return _rejected(AuthFlowRejection.callbackReplayed);
    }

    if (callback.hasError) {
      return _rejected(AuthFlowRejection.providerError);
    }
    final SecretString? code = callback.code;
    if (code == null || callback.state.isEmpty) {
      return _rejected(AuthFlowRejection.malformedCallback);
    }
    if (!pending.state.matches(callback.state)) {
      return _rejected(AuthFlowRejection.stateMismatch);
    }

    // Commit to consuming the callback exactly once BEFORE the exchange, so a
    // replay cannot re-drive the flow even if the exchange itself fails.
    await store.recordConsumedReceipt(pending.requestId);
    await store.writePendingAuthorization(null);

    final OAuthTokenResponse response;
    try {
      response = await gateway.exchangeAuthorizationCode(
        code: code,
        codeVerifier: pending.pkce.verifier,
        redirectUri: pending.redirectUri,
        deviceId: deviceId,
      );
    } on OAuthGatewayException catch (error) {
      return _gatewayFailure<AuthStatus>(error, resetPhase: true);
    }

    // Nonce binds the ID token to this request; a mismatch is a replay/mix-up.
    if (!pending.nonce.matches(response.idTokenNonce)) {
      return _rejected(AuthFlowRejection.nonceMismatch);
    }

    // Account-swap detection: a different account than the one already stored
    // must not silently take over. Require unlink/preview.
    final AuthTokens? existing = await store.readTokens();
    if (existing != null &&
        existing.accountFingerprint != response.accountFingerprint) {
      _status = AuthStatus(
        phase: AuthPhase.accountChanged,
        hasLink: _hasLink,
        accountFingerprint: existing.accountFingerprint,
      );
      return Success<AuthStatus>(status);
    }

    final AuthTokens next = AuthTokens(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken,
      tokenType: response.tokenType,
      accessTokenExpiresAtUtcMicros: _expiryMicros(response.expiresIn),
      accountFingerprint: response.accountFingerprint,
    );
    await store.compareAndSwapTokens(
      expectedGeneration:
          existing?.rotationGeneration ?? kNoStoredTokensGeneration,
      next: next,
    );
    _markAuthenticated(response.accountFingerprint);
    return Success<AuthStatus>(status);
  }

  /// Rotates the session using the stored refresh token with atomic
  /// replacement (R-SYNC-001). The old refresh token is invalidated on use, and
  /// the compare-and-swap on the rotation generation guarantees two concurrent
  /// refreshes can never both persist — there is no window with two valid
  /// refresh tokens.
  Future<Result<AuthStatus>> refreshSession() async {
    final AuthTokens? current = await store.readTokens();
    if (current == null) {
      _status = AuthStatus.signedOut();
      return _failure<AuthStatus>(
        kind: FailureKind.permission,
        code: 'sync.auth.no_session',
        retryable: false,
      );
    }

    final OAuthTokenResponse response;
    try {
      response = await gateway.refresh(
        refreshToken: current.refreshToken,
        deviceId: deviceId,
      );
    } on OAuthGatewayException catch (error) {
      switch (error.kind) {
        case OAuthGatewayErrorKind.invalidGrant:
          _status = _status.copyWith(phase: AuthPhase.expired);
          return _failure<AuthStatus>(
            kind: FailureKind.permission,
            code: 'sync.auth.refresh_invalid',
            retryable: false,
          );
        case OAuthGatewayErrorKind.revokedDevice:
          await _clearTokens(current);
          _status = AuthStatus(phase: AuthPhase.revoked, hasLink: _hasLink);
          return _failure<AuthStatus>(
            kind: FailureKind.permission,
            code: 'sync.auth.revoked',
            retryable: false,
          );
        case OAuthGatewayErrorKind.network:
        case OAuthGatewayErrorKind.server:
        case OAuthGatewayErrorKind.invalidRequest:
          return _gatewayFailure<AuthStatus>(error, resetPhase: false);
      }
    }

    final AuthTokens rotated;
    try {
      rotated = current.rotate(
        newAccessToken: response.accessToken,
        newRefreshToken: response.refreshToken,
        newAccessTokenExpiresAtUtcMicros: _expiryMicros(response.expiresIn),
        responseFingerprint: response.accountFingerprint,
        newTokenType: response.tokenType,
      );
    } on AccountMismatchException {
      _status = _status.copyWith(phase: AuthPhase.accountChanged);
      return Success<AuthStatus>(status);
    }

    // Atomic replacement. If the swap loses to a concurrent rotation, the store
    // already holds a single newer token set; we simply adopt it. Either way,
    // exactly one refresh token is valid.
    final bool swapped = await store.compareAndSwapTokens(
      expectedGeneration: current.rotationGeneration,
      next: rotated,
    );
    if (!swapped) {
      await store.readTokens();
    }
    _markAuthenticated(response.accountFingerprint);
    return Success<AuthStatus>(status);
  }

  /// Signs out: best-effort server revocation, then clears local tokens. Local
  /// user records are never deleted here; [retainLocalData] communicates the
  /// user's choice to the caller that owns local data (R-SYNC-008).
  Future<Result<bool>> signOut({required bool retainLocalData}) async {
    final AuthTokens? current = await store.readTokens();
    if (current != null) {
      try {
        await gateway.revoke(
          refreshToken: current.refreshToken,
          deviceId: deviceId,
        );
      } on OAuthGatewayException {
        // Revocation is best-effort; local tokens are cleared regardless.
      }
      await _clearTokens(current);
    }
    await store.writePendingAuthorization(null);
    _status = AuthStatus.signedOut();
    _lastAuthenticatedAtUtcMicros = null;
    return Success<bool>(retainLocalData);
  }

  /// Handles a server-side revocation signal (e.g. a push/pull rejected the
  /// device). Clears local tokens and requires reauthentication.
  Future<void> handleRevocation() async {
    final AuthTokens? current = await store.readTokens();
    if (current != null) {
      await _clearTokens(current);
    }
    _status = AuthStatus(phase: AuthPhase.revoked, hasLink: _hasLink);
  }

  /// Marks that remote deletion was requested; it requires recent
  /// reauthentication before proceeding (R-SYNC-008, data-model.md §6).
  void requireRemoteDeleteReauth() {
    _status = _status.copyWith(phase: AuthPhase.remoteDeleteReauth);
  }

  /// Whether the account reauthenticated within [AuthFlowConfig.recentReauthWindow].
  /// Remote deletion is only permitted when this is true.
  bool get hasRecentReauthentication {
    final int? at = _lastAuthenticatedAtUtcMicros;
    if (at == null) {
      return false;
    }
    final int elapsed = clock.utcNow().microsecondsSinceEpoch - at;
    return elapsed >= 0 && elapsed <= config.recentReauthWindow.inMicroseconds;
  }

  void _markAuthenticated(AccountFingerprint fingerprint) {
    _lastAuthenticatedAtUtcMicros = clock.utcNow().microsecondsSinceEpoch;
    _status = AuthStatus(
      phase: AuthPhase.authenticated,
      hasLink: _hasLink,
      accountFingerprint: fingerprint,
    );
  }

  Future<void> _clearTokens(AuthTokens current) async {
    await store.compareAndSwapTokens(
      expectedGeneration: current.rotationGeneration,
      next: null,
    );
  }

  int _expiryMicros(Duration expiresIn) =>
      clock.utcNow().microsecondsSinceEpoch + expiresIn.inMicroseconds;

  Result<AuthStatus> _rejected(AuthFlowRejection rejection) {
    final (FailureKind kind, bool retryable) = switch (rejection) {
      AuthFlowRejection.redirectNotAllowed => (FailureKind.validation, false),
      AuthFlowRejection.stateMismatch => (FailureKind.permission, false),
      AuthFlowRejection.nonceMismatch => (FailureKind.permission, false),
      AuthFlowRejection.providerError => (FailureKind.permission, false),
      AuthFlowRejection.callbackReplayed => (FailureKind.conflict, false),
      AuthFlowRejection.noPendingAuthorization => (
        FailureKind.validation,
        false,
      ),
      AuthFlowRejection.malformedCallback => (FailureKind.validation, false),
    };
    return _failure<AuthStatus>(
      kind: kind,
      code: 'sync.auth.${rejection.name}',
      retryable: retryable,
    );
  }

  Result<T> _gatewayFailure<T>(
    OAuthGatewayException error, {
    required bool resetPhase,
  }) {
    if (resetPhase) {
      _status = _status.copyWith(phase: AuthPhase.signedOut);
    }
    final (FailureKind kind, bool retryable) = switch (error.kind) {
      OAuthGatewayErrorKind.network => (FailureKind.network, true),
      OAuthGatewayErrorKind.server => (FailureKind.network, true),
      OAuthGatewayErrorKind.invalidGrant => (FailureKind.permission, false),
      OAuthGatewayErrorKind.revokedDevice => (FailureKind.permission, false),
      OAuthGatewayErrorKind.invalidRequest => (FailureKind.validation, false),
    };
    return _failure<T>(
      kind: kind,
      code: 'sync.auth.gateway_${error.kind.name}',
      retryable: retryable,
    );
  }

  Result<T> _failure<T>({
    required FailureKind kind,
    required String code,
    required bool retryable,
  }) => Failed<T>(
    Failure(kind: kind, code: code, safeMessageKey: code, retryable: retryable),
  );
}
