/// Deterministic fakes for the Supabase auth state machine's integration
/// boundary: secure random bytes, a real SHA-256 hasher (via the `crypto` dev
/// dependency), an in-memory secure token store with true compare-and-swap
/// semantics, and a scriptable OAuth gateway. No network, no platform storage.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';

/// A deterministic, seedable byte source. Each call returns fresh, distinct
/// bytes so successive `state`/`nonce`/verifier values differ, while remaining
/// fully reproducible for a given [seed].
final class FakeSecureRandomSource implements SecureRandomSource {
  FakeSecureRandomSource({int seed = 0x12345678}) : _state = seed & 0xffffffff;

  int _state;

  @override
  Uint8List nextBytes(int count) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'Must be >= 1.');
    }
    final Uint8List out = Uint8List(count);
    for (int i = 0; i < count; i += 1) {
      // xorshift32 — deterministic and well-distributed for test entropy.
      _state ^= (_state << 13) & 0xffffffff;
      _state ^= _state >> 17;
      _state ^= (_state << 5) & 0xffffffff;
      out[i] = _state & 0xff;
    }
    return out;
  }
}

/// The real SHA-256 digest, used so PKCE verification exercises the true
/// S256 relationship rather than a stub.
final class RealSha256Hasher implements Sha256Hasher {
  const RealSha256Hasher();

  @override
  Uint8List digest(Uint8List input) =>
      Uint8List.fromList(crypto.sha256.convert(input).bytes);
}

/// In-memory secure storage with genuine compare-and-swap on the rotation
/// generation, mirroring the atomicity a platform adapter must provide.
final class InMemorySecureTokenStore implements SecureTokenStore {
  AuthTokens? _tokens;
  PendingAuthorization? _pending;
  final Set<String> _consumed = <String>{};

  int swapAttempts = 0;
  int swapSuccesses = 0;

  @override
  Future<AuthTokens?> readTokens() async => _tokens;

  @override
  Future<bool> compareAndSwapTokens({
    required int expectedGeneration,
    required AuthTokens? next,
  }) async {
    swapAttempts += 1;
    final int currentGeneration =
        _tokens?.rotationGeneration ?? kNoStoredTokensGeneration;
    if (currentGeneration != expectedGeneration) {
      return false;
    }
    _tokens = next;
    swapSuccesses += 1;
    return true;
  }

  @override
  Future<PendingAuthorization?> readPendingAuthorization() async => _pending;

  @override
  Future<void> writePendingAuthorization(PendingAuthorization? pending) async {
    _pending = pending;
  }

  @override
  Future<Set<String>> readConsumedReceipts() async =>
      Set<String>.unmodifiable(_consumed);

  @override
  Future<void> recordConsumedReceipt(String receiptId) async {
    _consumed.add(receiptId);
  }
}

/// A scriptable OAuth gateway. By default it echoes the pending request's nonce
/// (captured via [nextNonce]) and issues incrementing token values so refresh
/// rotation produces distinct refresh tokens.
final class FakeOAuthGateway implements OAuthGateway {
  FakeOAuthGateway({
    required this.accountFingerprint,
    this.nextNonce = '',
    this.tokenType = 'bearer',
    this.expiresIn = const Duration(hours: 1),
  });

  /// The account the gateway authenticates as. Change it to simulate an
  /// account swap.
  AccountFingerprint accountFingerprint;

  /// The nonce the gateway will echo in the ID token for the next exchange.
  String nextNonce;
  String tokenType;
  Duration expiresIn;

  /// When set, the next matching call throws instead of returning.
  OAuthGatewayException? exchangeError;
  OAuthGatewayException? refreshError;

  /// When set, refresh returns this fingerprint (to simulate a mid-session
  /// account swap).
  AccountFingerprint? refreshFingerprintOverride;

  int _tokenSeq = 0;
  int exchangeCalls = 0;
  int refreshCalls = 0;
  int revokeCalls = 0;

  /// Refresh tokens the gateway has considered "current"; a rotation invalidates
  /// the previous one. Used to assert single-use rotation in tests.
  final List<String> issuedRefreshTokens = <String>[];

  OAuthTokenResponse _issue({String? nonce, AccountFingerprint? fingerprint}) {
    _tokenSeq += 1;
    final String refresh = 'refresh-$_tokenSeq';
    issuedRefreshTokens.add(refresh);
    return OAuthTokenResponse(
      accessToken: SecretString('access-$_tokenSeq'),
      refreshToken: SecretString(refresh),
      tokenType: tokenType,
      expiresIn: expiresIn,
      idTokenNonce: nonce ?? nextNonce,
      accountFingerprint: fingerprint ?? accountFingerprint,
    );
  }

  @override
  Future<OAuthTokenResponse> exchangeAuthorizationCode({
    required SecretString code,
    required CodeVerifier codeVerifier,
    required String redirectUri,
    required DeviceId deviceId,
  }) async {
    exchangeCalls += 1;
    final OAuthGatewayException? error = exchangeError;
    if (error != null) {
      throw error;
    }
    return _issue();
  }

  @override
  Future<OAuthTokenResponse> refresh({
    required SecretString refreshToken,
    required DeviceId deviceId,
  }) async {
    refreshCalls += 1;
    final OAuthGatewayException? error = refreshError;
    if (error != null) {
      throw error;
    }
    return _issue(
      nonce: nextNonce,
      fingerprint: refreshFingerprintOverride ?? accountFingerprint,
    );
  }

  @override
  Future<void> revoke({
    required SecretString refreshToken,
    required DeviceId deviceId,
  }) async {
    revokeCalls += 1;
  }
}
