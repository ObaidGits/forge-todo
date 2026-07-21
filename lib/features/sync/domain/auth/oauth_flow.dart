/// The redirect authorization flow: state and nonce anti-forgery values, an
/// exact redirect allowlist, the pending-request record, authorization request
/// building, callback parsing, and the one-use callback guard (R-SYNC-001,
/// design.md §13, data-model.md §6 "one-use callback receipts").
///
/// Everything here is pure domain. Randomness for `state`/`nonce` comes through
/// the injected [SecureRandomSource]; SHA-256 for PKCE comes through
/// [Sha256Hasher]. There are no Flutter/DB/network/Supabase imports.
library;

import 'package:forge/features/sync/domain/auth/auth_secret.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';

/// Why the redirect flow rejected an input without side effects. Each reason is
/// stable and presentation-safe; it never repeats the offending value.
enum AuthFlowRejection {
  /// The callback's redirect URI is not an exact allowlist match.
  redirectNotAllowed,

  /// The callback `state` did not match the pending request (CSRF/mix-up).
  stateMismatch,

  /// The ID token `nonce` did not match the pending request (replay/mix-up).
  nonceMismatch,

  /// The callback carried a provider `error` parameter.
  providerError,

  /// The callback was already consumed once (replay).
  callbackReplayed,

  /// There is no pending authorization to match the callback against.
  noPendingAuthorization,

  /// The callback was structurally malformed (missing code/state).
  malformedCallback,
}

/// Raised when the redirect flow refuses to proceed. Carries a stable
/// [AuthFlowRejection] and never the offending secret.
final class AuthFlowException implements Exception {
  const AuthFlowException(this.rejection);

  final AuthFlowRejection rejection;

  @override
  String toString() => 'AuthFlowException(${rejection.name})';
}

/// A single-use anti-forgery `state` value bound to one authorization request.
final class OAuthState {
  const OAuthState(this.value);

  final SecretString value;

  bool matches(String candidate) => value == SecretString(candidate);

  @override
  String toString() => 'OAuthState(<redacted>)';
}

/// A single-use `nonce` bound into the authorization request and verified
/// against the returned ID token to prevent token replay/injection.
final class OAuthNonce {
  const OAuthNonce(this.value);

  final SecretString value;

  bool matches(String candidate) => value == SecretString(candidate);

  @override
  String toString() => 'OAuthNonce(<redacted>)';
}

/// Generates high-entropy `state` and `nonce` values (256 bits, base64url).
final class AntiForgeryFactory {
  const AntiForgeryFactory(this._random);

  final SecureRandomSource _random;

  OAuthState createState() =>
      OAuthState(SecretString(base64UrlNoPad(_random.nextBytes(32))));

  OAuthNonce createNonce() =>
      OAuthNonce(SecretString(base64UrlNoPad(_random.nextBytes(32))));
}

/// An exact, case-sensitive redirect URI allowlist (R-SYNC-001 "exact
/// redirects"; design.md §13). No prefix, wildcard, host, or path matching is
/// performed: the callback redirect must equal a registered value byte for
/// byte after canonicalization. This is deliberately stricter than the general
/// [UriPolicy] because an OAuth redirect is a fixed, reviewed constant.
final class RedirectUriAllowlist {
  RedirectUriAllowlist(Iterable<String> allowed)
    : _allowed = Set<String>.unmodifiable(allowed.map(_canonicalize)) {
    if (_allowed.isEmpty) {
      throw ArgumentError.value(
        allowed,
        'allowed',
        'At least one redirect URI must be registered.',
      );
    }
  }

  final Set<String> _allowed;

  Iterable<String> get allowed => _allowed;

  /// True only when [uri] canonicalizes to a registered redirect exactly.
  bool isAllowed(String uri) {
    final String? canonical = _tryCanonicalize(uri);
    return canonical != null && _allowed.contains(canonical);
  }

  static String _canonicalize(String raw) {
    final String? canonical = _tryCanonicalize(raw);
    if (canonical == null) {
      throw ArgumentError.value(raw, 'uri', 'Invalid redirect URI.');
    }
    return canonical;
  }

  /// Canonicalizes scheme/host to lower case and drops any query/fragment. A
  /// registered redirect must have no query or fragment; a callback presenting
  /// extra query/fragment on the redirect target is treated as a mismatch.
  static String? _tryCanonicalize(String raw) {
    if (raw.trim() != raw || raw.isEmpty) {
      return null;
    }
    final Uri? parsed = Uri.tryParse(raw);
    if (parsed == null || !parsed.hasScheme) {
      return null;
    }
    if (parsed.query.isNotEmpty || parsed.fragment.isNotEmpty) {
      return null;
    }
    final Uri normalized = parsed.replace(
      scheme: parsed.scheme.toLowerCase(),
      host: parsed.hasAuthority ? parsed.host.toLowerCase() : null,
    );
    return normalized.toString();
  }
}

/// The durable record of an in-flight authorization request. It is persisted
/// (through secure storage) so a callback that returns after an app restart can
/// still be verified. It binds the PKCE verifier, `state`, `nonce`, and the
/// exact redirect URI that was requested.
final class PendingAuthorization {
  PendingAuthorization({
    required this.requestId,
    required this.pkce,
    required this.state,
    required this.nonce,
    required this.redirectUri,
    required this.createdAtUtcMicros,
    this.isReauthentication = false,
  });

  /// A stable id (UUIDv7) for this request; also used as the one-use callback
  /// receipt key.
  final String requestId;
  final PkcePair pkce;
  final OAuthState state;
  final OAuthNonce nonce;
  final String redirectUri;
  final int createdAtUtcMicros;

  /// True when this request re-establishes an existing link (reauthentication
  /// for session refresh or remote delete) rather than a first-time sign-in.
  final bool isReauthentication;
}

/// The authorization request parameters the transport turns into an authorize
/// URL. Only opaque, non-secret-by-design query parameters live here; the
/// `state`/`nonce` are revealed exactly once when the URL is built at the
/// transport boundary.
final class AuthorizationRequest {
  AuthorizationRequest({
    required this.responseType,
    required this.redirectUri,
    required this.codeChallenge,
    required this.codeChallengeMethod,
    required this.state,
    required this.nonce,
    required this.scopes,
  });

  final String responseType;
  final String redirectUri;
  final String codeChallenge;
  final String codeChallengeMethod;
  final OAuthState state;
  final OAuthNonce nonce;
  final List<String> scopes;

  /// Builds the query parameter map for the authorize endpoint. `state` and
  /// `nonce` are revealed here because they must travel on the wire; every
  /// other rendering keeps them redacted.
  Map<String, String> toQueryParameters() => <String, String>{
    'response_type': responseType,
    'redirect_uri': redirectUri,
    'code_challenge': codeChallenge,
    'code_challenge_method': codeChallengeMethod,
    'state': state.value.reveal(),
    'nonce': nonce.value.reveal(),
    'scope': scopes.join(' '),
  };
}

/// The parsed inbound callback. The authorization `code` is a secret; `state`
/// is compared against the pending request.
final class AuthCallback {
  const AuthCallback({
    required this.redirectUri,
    required this.state,
    this.code,
    this.error,
  });

  /// Parses `redirectUri` (the full callback URL) into its `code`/`state`/
  /// `error` parameters. Returns a callback whose [state] is empty when absent.
  factory AuthCallback.parse(String rawCallback) {
    final Uri uri = Uri.parse(rawCallback);
    // Reconstruct the redirect target with query and fragment stripped, so it
    // can be matched byte for byte against the exact allowlist. Assigning an
    // empty query via `replace` would leave a trailing `?`.
    final String redirect = Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.hasAuthority ? uri.host : null,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
    final Map<String, String> params = uri.queryParameters;
    return AuthCallback(
      redirectUri: redirect,
      state: params['state'] ?? '',
      code: params['code'] == null ? null : SecretString(params['code']!),
      error: params['error'],
    );
  }

  /// The redirect target the callback arrived on (query/fragment stripped),
  /// checked against the exact allowlist.
  final String redirectUri;
  final String state;
  final SecretString? code;
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;
}

/// Enforces that a callback receipt (keyed by the pending request id) is
/// consumed exactly once. A replayed callback is rejected. The set of consumed
/// receipts is bounded by retention elsewhere; here it is the authoritative
/// idempotency guard for the redirect leg.
final class OneUseCallbackGuard {
  OneUseCallbackGuard({Set<String>? alreadyConsumed})
    : _consumed = <String>{...?alreadyConsumed};

  final Set<String> _consumed;

  /// The receipts consumed so far (for durable persistence/inspection).
  Set<String> get consumed => Set<String>.unmodifiable(_consumed);

  /// Returns true if [receiptId] was already consumed.
  bool isConsumed(String receiptId) => _consumed.contains(receiptId);

  /// Consumes [receiptId], returning true on the first call and false on every
  /// replay. The operation is idempotent in effect: the receipt stays consumed.
  bool consume(String receiptId) => _consumed.add(receiptId);
}
