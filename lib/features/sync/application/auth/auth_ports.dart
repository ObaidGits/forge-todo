/// Integration-boundary ports for the Supabase auth state machine (design.md
/// §9/§13). The concrete Supabase client and the platform secure storage are
/// replaceable adapters wired at the composition root; the state machine speaks
/// only to these contracts and is exercised in tests with deterministic fakes.
///
/// Tokens are NEVER persisted in the Drift database in plaintext — they live
/// exclusively behind [SecureTokenStore], which maps to platform secure storage
/// (R-SEC-002, data-model.md §3 "scheduler tokens" are local-only/never
/// replicated).
library;

import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';

/// A stable classification of an auth gateway failure, mapped from provider
/// responses without leaking transport detail.
enum OAuthGatewayErrorKind {
  /// Transient connectivity/TLS failure; retryable.
  network,

  /// The provider returned a server-side error; retryable.
  server,

  /// The authorization code or refresh token was invalid/expired/consumed. Not
  /// retryable with the same input; forces reauthentication.
  invalidGrant,

  /// The device/session was revoked server-side.
  revokedDevice,

  /// The request was malformed or rejected (e.g. bad redirect); not retryable.
  invalidRequest,
}

/// Raised by an [OAuthGateway] adapter. Carries a stable [kind]; the redacted
/// [cause] never contains tokens or codes.
final class OAuthGatewayException implements Exception {
  const OAuthGatewayException(this.kind, {this.cause});

  final OAuthGatewayErrorKind kind;
  final String? cause;

  @override
  String toString() => 'OAuthGatewayException(${kind.name})';
}

/// The token payload returned by the provider for a code exchange or refresh.
/// The `idTokenNonce` is the `nonce` claim extracted from the verified ID
/// token; the machine compares it against the pending request.
final class OAuthTokenResponse {
  OAuthTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.idTokenNonce,
    required this.accountFingerprint,
  });

  final SecretString accessToken;
  final SecretString refreshToken;
  final String tokenType;
  final Duration expiresIn;
  final String idTokenNonce;
  final AccountFingerprint accountFingerprint;
}

/// The replaceable auth transport (Supabase-compatible). It performs the PKCE
/// code exchange, refresh-token rotation, and revocation. It never persists
/// anything; persistence is the state machine's responsibility through
/// [SecureTokenStore].
abstract interface class OAuthGateway {
  /// Exchanges an authorization [code] for tokens, sending the PKCE
  /// [codeVerifier] and the exact [redirectUri]. The provider validates the
  /// verifier against the earlier challenge.
  Future<OAuthTokenResponse> exchangeAuthorizationCode({
    required SecretString code,
    required CodeVerifier codeVerifier,
    required String redirectUri,
    required DeviceId deviceId,
  });

  /// Rotates the session using [refreshToken]. On success the old refresh token
  /// is invalidated by the provider (single-use rotation).
  Future<OAuthTokenResponse> refresh({
    required SecretString refreshToken,
    required DeviceId deviceId,
  });

  /// Revokes the session server-side (sign-out). Best-effort; a network failure
  /// still lets the client clear local tokens.
  Future<void> revoke({
    required SecretString refreshToken,
    required DeviceId deviceId,
  });
}

/// Platform secure storage for auth material. Tokens, the in-flight pending
/// authorization (which holds the PKCE verifier/state/nonce secrets), and the
/// one-use callback receipts all live here — never in the Drift database.
///
/// [compareAndSwapTokens] is the atomicity primitive for refresh replacement:
/// it applies [next] only if the currently stored generation equals
/// [expectedGeneration], so two concurrent rotations cannot both persist and no
/// state ever holds two usable refresh tokens. A first write uses
/// [kNoStoredTokensGeneration]; a clear passes `next: null`.
abstract interface class SecureTokenStore {
  Future<AuthTokens?> readTokens();

  Future<bool> compareAndSwapTokens({
    required int expectedGeneration,
    required AuthTokens? next,
  });

  Future<PendingAuthorization?> readPendingAuthorization();

  Future<void> writePendingAuthorization(PendingAuthorization? pending);

  Future<Set<String>> readConsumedReceipts();

  Future<void> recordConsumedReceipt(String receiptId);
}
