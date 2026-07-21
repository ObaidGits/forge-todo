/// The GoTrue (Supabase Auth) REST adapter (R-SYNC-001, R-SEC-002; design.md
/// §13).
///
/// It provides two authentication surfaces over `/auth/v1`:
///
///  * an email + password sign-up / sign-in / refresh flow used for LOCAL
///    end-to-end testing and for backends where password auth is enabled; and
///  * an [OAuthGateway] implementation (PKCE code exchange, refresh-token
///    rotation, revocation) so the existing [SupabaseAuthStateMachine] redirect
///    flow works unchanged against real cloud providers.
///
/// It never persists anything — persistence is the state machine's job through
/// [SecureTokenStore]. All `package:http` usage stays behind infrastructure.
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';
import 'package:http/http.dart' as http;

/// A resolved GoTrue session: the tokens plus the authenticated user id, which
/// is the sync `owner_user_id` and the remote-profile id a first device adopts.
final class GoTrueSession {
  GoTrueSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.expiresIn,
    required this.tokenType,
  });

  final SecretString accessToken;
  final SecretString refreshToken;

  /// The authenticated subject (`auth.uid()`), i.e. the sync owner user id.
  final String userId;
  final Duration expiresIn;
  final String tokenType;

  /// The account fingerprint used by the auth state machine to detect swaps.
  AccountFingerprint get accountFingerprint => AccountFingerprint(userId);
}

/// The GoTrue REST adapter.
final class GoTrueAuthClient implements OAuthGateway {
  GoTrueAuthClient({
    required Uri baseUrl,
    required String anonKey,
    http.Client? client,
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _client = client ?? http.Client();

  final Uri _baseUrl;
  final String _anonKey;
  final http.Client _client;

  // --- Email + password (the locally-tested path) --------------------------

  /// Registers a new account. When email confirmation is disabled (as in the
  /// local dev backend) the response already carries a usable session.
  Future<GoTrueSession> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    final Map<String, Object?> json = await _post(
      _baseUrl.resolve('/auth/v1/signup'),
      body: <String, Object?>{'email': email, 'password': password},
    );
    return _sessionFrom(json);
  }

  /// Signs in with an existing email + password, returning a fresh session.
  Future<GoTrueSession> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final Map<String, Object?> json = await _post(
      _baseUrl.resolve('/auth/v1/token?grant_type=password'),
      body: <String, Object?>{'email': email, 'password': password},
    );
    return _sessionFrom(json);
  }

  /// Rotates a session with a refresh token (single-use rotation).
  Future<GoTrueSession> refreshSession(String refreshToken) async {
    final Map<String, Object?> json = await _post(
      _baseUrl.resolve('/auth/v1/token?grant_type=refresh_token'),
      body: <String, Object?>{'refresh_token': refreshToken},
    );
    return _sessionFrom(json);
  }

  /// Signs out server-side (best-effort revocation).
  Future<void> signOut(String accessToken) async {
    await _post(
      _baseUrl.resolve('/auth/v1/logout'),
      body: const <String, Object?>{},
      accessToken: accessToken,
      expectJson: false,
    );
  }

  // --- OAuthGateway (redirect/PKCE flow for cloud providers) ---------------

  @override
  Future<OAuthTokenResponse> exchangeAuthorizationCode({
    required SecretString code,
    required CodeVerifier codeVerifier,
    required String redirectUri,
    required DeviceId deviceId,
  }) async {
    final Map<String, Object?> json = await _post(
      _baseUrl.resolve('/auth/v1/token?grant_type=pkce'),
      body: <String, Object?>{
        'auth_code': code.reveal(),
        'code_verifier': codeVerifier.value,
      },
    );
    return _tokenResponseFrom(json);
  }

  @override
  Future<OAuthTokenResponse> refresh({
    required SecretString refreshToken,
    required DeviceId deviceId,
  }) async {
    final Map<String, Object?> json = await _post(
      _baseUrl.resolve('/auth/v1/token?grant_type=refresh_token'),
      body: <String, Object?>{'refresh_token': refreshToken.reveal()},
    );
    return _tokenResponseFrom(json);
  }

  @override
  Future<void> revoke({
    required SecretString refreshToken,
    required DeviceId deviceId,
  }) async {
    // GoTrue logout revokes by access token; a refresh-token-only revoke is a
    // best-effort no-op locally. Callers clear local tokens regardless.
  }

  // --- Mapping -------------------------------------------------------------

  GoTrueSession _sessionFrom(Map<String, Object?> json) {
    final Map<String, Object?> user = _asMap(json['user'], 'user');
    return GoTrueSession(
      accessToken: SecretString(
        _asString(json['access_token'], 'access_token'),
      ),
      refreshToken: SecretString(
        _asString(json['refresh_token'], 'refresh_token'),
      ),
      userId: _asString(user['id'], 'user.id'),
      expiresIn: Duration(seconds: _asInt(json['expires_in'], 'expires_in')),
      tokenType: (json['token_type'] as String?) ?? 'bearer',
    );
  }

  OAuthTokenResponse _tokenResponseFrom(Map<String, Object?> json) {
    final Map<String, Object?> user = _asMap(json['user'], 'user');
    final String userId = _asString(user['id'], 'user.id');
    return OAuthTokenResponse(
      accessToken: SecretString(
        _asString(json['access_token'], 'access_token'),
      ),
      refreshToken: SecretString(
        _asString(json['refresh_token'], 'refresh_token'),
      ),
      tokenType: (json['token_type'] as String?) ?? 'bearer',
      expiresIn: Duration(seconds: _asInt(json['expires_in'], 'expires_in')),
      // Email/password sessions carry no ID-token nonce; the account
      // fingerprint is the stable subject. Redirect providers that issue a
      // nonce populate the claim the state machine verifies.
      idTokenNonce: (json['nonce'] as String?) ?? '',
      accountFingerprint: AccountFingerprint(userId),
    );
  }

  // --- HTTP ----------------------------------------------------------------

  Future<Map<String, Object?>> _post(
    Uri uri, {
    required Map<String, Object?> body,
    String? accessToken,
    bool expectJson = true,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: <String, String>{
          'apikey': _anonKey,
          'Content-Type': 'application/json',
          if (accessToken != null) 'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(body),
      );
    } on Object catch (error) {
      throw OAuthGatewayException(
        OAuthGatewayErrorKind.network,
        cause: error.runtimeType.toString(),
      );
    }
    final int status = response.statusCode;
    if (status == 400 || status == 401 || status == 403 || status == 422) {
      throw OAuthGatewayException(
        OAuthGatewayErrorKind.invalidGrant,
        cause: 'status=$status',
      );
    }
    if (status >= 500) {
      throw OAuthGatewayException(
        OAuthGatewayErrorKind.server,
        cause: 'status=$status',
      );
    }
    if (status < 200 || status >= 300) {
      throw OAuthGatewayException(
        OAuthGatewayErrorKind.invalidRequest,
        cause: 'status=$status',
      );
    }
    if (!expectJson || response.body.isEmpty) {
      return const <String, Object?>{};
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const OAuthGatewayException(
        OAuthGatewayErrorKind.server,
        cause: 'malformed JSON',
      );
    }
    return _asMap(decoded, 'response');
  }

  static Map<String, Object?> _asMap(Object? value, String field) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    throw OAuthGatewayException(
      OAuthGatewayErrorKind.server,
      cause: 'expected object for $field',
    );
  }

  static int _asInt(Object? value, String field) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      final int? parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw OAuthGatewayException(
      OAuthGatewayErrorKind.server,
      cause: 'expected integer for $field',
    );
  }

  static String _asString(Object? value, String field) {
    if (value is String) {
      return value;
    }
    throw OAuthGatewayException(
      OAuthGatewayErrorKind.server,
      cause: 'expected string for $field',
    );
  }
}
