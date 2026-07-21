/// The authenticated session token set and its atomic rotation semantics
/// (R-SYNC-001 "atomic refresh replacement", R-SEC-002 short-lived tokens,
/// design.md §13 "atomic refresh replacement").
///
/// Tokens are single-valued: the client persists exactly one [AuthTokens]
/// record. Rotation produces a brand-new immutable successor with a strictly
/// higher [rotationGeneration]; there is never a persisted state in which two
/// different refresh tokens are both usable. The store applies the successor
/// with a compare-and-swap on [rotationGeneration] so two concurrent refreshes
/// cannot both win (see `SecureTokenStore`).
library;

import 'package:forge/features/sync/domain/auth/auth_secret.dart';

/// A stable, non-secret fingerprint of the authenticated account subject. Used
/// to detect account swaps: a refresh or callback whose fingerprint differs
/// from the linked account is `account_changed`, never a silent takeover.
final class AccountFingerprint {
  AccountFingerprint(this.value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'Must not be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AccountFingerprint && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AccountFingerprint($value)';
}

/// Raised when a rotation response belongs to a different account than the one
/// currently held. The caller maps this to `account_changed`.
final class AccountMismatchException implements Exception {
  const AccountMismatchException();

  @override
  String toString() => 'AccountMismatchException';
}

/// The generation sentinel used when no tokens are stored yet. The first write
/// compare-and-swaps against this value.
const int kNoStoredTokensGeneration = -1;

/// An immutable authenticated session token set.
final class AuthTokens {
  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.accessTokenExpiresAtUtcMicros,
    required this.accountFingerprint,
    this.rotationGeneration = 0,
  }) {
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw ArgumentError('Access and refresh tokens must not be empty.');
    }
    if (rotationGeneration < 0) {
      throw ArgumentError.value(
        rotationGeneration,
        'rotationGeneration',
        'Must be nonnegative.',
      );
    }
  }

  final SecretString accessToken;
  final SecretString refreshToken;
  final String tokenType;

  /// Absolute UTC expiry of the short-lived access token, in microseconds.
  final int accessTokenExpiresAtUtcMicros;
  final AccountFingerprint accountFingerprint;

  /// Monotonic counter incremented on every rotation. Doubles as the
  /// compare-and-swap token for atomic replacement.
  final int rotationGeneration;

  /// Whether the access token is still valid at [nowUtcMicros] (with an
  /// optional [skew] treated as already-expired to force early refresh).
  bool accessTokenValid(int nowUtcMicros, {Duration skew = Duration.zero}) =>
      nowUtcMicros + skew.inMicroseconds < accessTokenExpiresAtUtcMicros;

  /// Produces the rotated successor. The refresh token is replaced (the old one
  /// is invalidated server-side on use), the access token and expiry are
  /// refreshed, and the generation strictly increases. The account fingerprint
  /// must be unchanged; a differing fingerprint is an account swap and throws
  /// [AccountMismatchException] rather than silently rotating into another
  /// account.
  AuthTokens rotate({
    required SecretString newAccessToken,
    required SecretString newRefreshToken,
    required int newAccessTokenExpiresAtUtcMicros,
    required AccountFingerprint responseFingerprint,
    String? newTokenType,
  }) {
    if (responseFingerprint != accountFingerprint) {
      throw const AccountMismatchException();
    }
    return AuthTokens(
      accessToken: newAccessToken,
      refreshToken: newRefreshToken,
      tokenType: newTokenType ?? tokenType,
      accessTokenExpiresAtUtcMicros: newAccessTokenExpiresAtUtcMicros,
      accountFingerprint: accountFingerprint,
      rotationGeneration: rotationGeneration + 1,
    );
  }

  @override
  String toString() =>
      'AuthTokens(gen=$rotationGeneration, account=${accountFingerprint.value}, '
      'tokens=<redacted>)';
}
