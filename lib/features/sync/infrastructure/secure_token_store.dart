/// Platform-agnostic [SecureTokenStore] implementations for the auth state
/// machine (R-SEC-002; design.md §13).
///
/// Tokens are NEVER written to the Drift database — they live only behind this
/// port. Two adapters are provided:
///
///  * [InMemorySecureTokenStore] — a fully in-memory store used in tests and as
///    the safe default when no platform secure storage is available; and
///  * [FileBackedSecureTokenStore] — persists the durable [AuthTokens] as JSON
///    under the app-support directory (0600-style, app-private) so a session
///    survives a restart without depending on libsecret/keychain. The transient
///    pending-authorization and one-use receipts stay in memory (they only
///    matter within a single redirect flow).
///
/// The compare-and-swap on the rotation generation is honoured so two
/// concurrent refreshes can never both persist (there is never a window with
/// two usable refresh tokens).
library;

import 'dart:convert';
import 'dart:io';

import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';

/// Shared JSON (de)serialization for [AuthTokens].
abstract final class AuthTokensCodec {
  static Map<String, Object?> encode(AuthTokens tokens) => <String, Object?>{
    'access_token': tokens.accessToken.reveal(),
    'refresh_token': tokens.refreshToken.reveal(),
    'token_type': tokens.tokenType,
    'access_token_expires_at_utc_micros': tokens.accessTokenExpiresAtUtcMicros,
    'account_fingerprint': tokens.accountFingerprint.value,
    'rotation_generation': tokens.rotationGeneration,
  };

  static AuthTokens decode(Map<String, Object?> json) => AuthTokens(
    accessToken: SecretString(json['access_token'] as String),
    refreshToken: SecretString(json['refresh_token'] as String),
    tokenType: (json['token_type'] as String?) ?? 'bearer',
    accessTokenExpiresAtUtcMicros:
        (json['access_token_expires_at_utc_micros'] as num).toInt(),
    accountFingerprint: AccountFingerprint(
      json['account_fingerprint'] as String,
    ),
    rotationGeneration: (json['rotation_generation'] as num?)?.toInt() ?? 0,
  );
}

/// A fully in-memory [SecureTokenStore].
final class InMemorySecureTokenStore implements SecureTokenStore {
  AuthTokens? _tokens;
  PendingAuthorization? _pending;
  final Set<String> _consumed = <String>{};

  @override
  Future<AuthTokens?> readTokens() async => _tokens;

  @override
  Future<bool> compareAndSwapTokens({
    required int expectedGeneration,
    required AuthTokens? next,
  }) async {
    final int currentGeneration =
        _tokens?.rotationGeneration ?? kNoStoredTokensGeneration;
    if (currentGeneration != expectedGeneration) {
      return false;
    }
    _tokens = next;
    return true;
  }

  @override
  Future<PendingAuthorization?> readPendingAuthorization() async => _pending;

  @override
  Future<void> writePendingAuthorization(PendingAuthorization? pending) async {
    _pending = pending;
  }

  @override
  Future<Set<String>> readConsumedReceipts() async => Set<String>.of(_consumed);

  @override
  Future<void> recordConsumedReceipt(String receiptId) async {
    _consumed.add(receiptId);
  }
}

/// A [SecureTokenStore] that persists the durable token set to an app-private
/// JSON file. Pending authorization and receipts remain in memory.
final class FileBackedSecureTokenStore implements SecureTokenStore {
  FileBackedSecureTokenStore(this._file);

  final File _file;

  PendingAuthorization? _pending;
  final Set<String> _consumed = <String>{};

  @override
  Future<AuthTokens?> readTokens() async {
    if (!_file.existsSync()) {
      return null;
    }
    final String contents = await _file.readAsString();
    if (contents.trim().isEmpty) {
      return null;
    }
    final Object? decoded = jsonDecode(contents);
    if (decoded is! Map) {
      return null;
    }
    return AuthTokensCodec.decode(
      decoded.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      ),
    );
  }

  @override
  Future<bool> compareAndSwapTokens({
    required int expectedGeneration,
    required AuthTokens? next,
  }) async {
    final AuthTokens? current = await readTokens();
    final int currentGeneration =
        current?.rotationGeneration ?? kNoStoredTokensGeneration;
    if (currentGeneration != expectedGeneration) {
      return false;
    }
    if (next == null) {
      if (_file.existsSync()) {
        await _file.delete();
      }
      return true;
    }
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode(AuthTokensCodec.encode(next)),
      flush: true,
    );
    return true;
  }

  @override
  Future<PendingAuthorization?> readPendingAuthorization() async => _pending;

  @override
  Future<void> writePendingAuthorization(PendingAuthorization? pending) async {
    _pending = pending;
  }

  @override
  Future<Set<String>> readConsumedReceipts() async => Set<String>.of(_consumed);

  @override
  Future<void> recordConsumedReceipt(String receiptId) async {
    _consumed.add(receiptId);
  }
}
