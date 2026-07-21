/// Proof Key for Code Exchange (RFC 7636) primitives for the Supabase redirect
/// auth flow (R-SYNC-001 "redirect auth uses PKCE/state/nonce", design.md §13).
///
/// These are pure domain values. The two capabilities PKCE needs that a client
/// cannot compute in a dependency-free `lib` — cryptographically secure random
/// bytes and SHA-256 — are expressed as narrow ports so the flow can be
/// exercised deterministically in tests and wired to platform/crypto adapters
/// at the composition root (mirrors the KeyVault deferred-boundary pattern).
library;

import 'dart:convert';
import 'dart:typed_data';

/// A source of cryptographically secure random bytes. Production supplies a
/// `Random.secure()`-backed adapter; tests supply a deterministic fake.
abstract interface class SecureRandomSource {
  /// Returns exactly [count] unbiased random bytes. Must throw if [count] < 1.
  Uint8List nextBytes(int count);
}

/// A SHA-256 digest port. Production supplies a `package:crypto` adapter in
/// infrastructure; tests supply the real digest or a deterministic fake. Kept
/// as a port so production `lib` carries no crypto dependency.
abstract interface class Sha256Hasher {
  /// Returns the 32-byte SHA-256 digest of [input].
  Uint8List digest(Uint8List input);
}

/// The PKCE transformation between the code verifier and code challenge.
enum PkceChallengeMethod {
  /// `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))`. Mandatory when
  /// the client can compute SHA-256; the only method Forge issues.
  s256('S256'),

  /// `code_challenge = code_verifier`. Modeled for completeness/verification
  /// but never issued by [PkceFactory].
  plain('plain');

  const PkceChallengeMethod(this.wireName);

  /// The value carried in the authorization request's `code_challenge_method`.
  final String wireName;
}

/// A high-entropy `code_verifier` restricted to the RFC 7636 unreserved
/// grammar (43–128 characters of `ALPHA / DIGIT / "-" / "." / "_" / "~"`).
final class CodeVerifier {
  CodeVerifier(this.value) {
    if (value.length < 43 || value.length > 128) {
      throw ArgumentError.value(
        value.length,
        'value',
        'PKCE code_verifier length must be 43..128.',
      );
    }
    if (!_grammar.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'value',
        'PKCE code_verifier contains a reserved character.',
      );
    }
  }

  final String value;

  static final RegExp _grammar = RegExp(r'^[A-Za-z0-9\-._~]+$');

  @override
  bool operator ==(Object other) =>
      other is CodeVerifier && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CodeVerifier(<redacted>)';
}

/// A `code_challenge` derived from a [CodeVerifier] under a [method].
final class CodeChallenge {
  const CodeChallenge(this.value, this.method);

  final String value;
  final PkceChallengeMethod method;

  @override
  bool operator ==(Object other) =>
      other is CodeChallenge && other.value == value && other.method == method;

  @override
  int get hashCode => Object.hash(value, method);

  @override
  String toString() => 'CodeChallenge($value, ${method.wireName})';
}

/// A verifier/challenge pair produced for a single authorization request.
final class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  final CodeVerifier verifier;
  final CodeChallenge challenge;
}

/// Creates and verifies PKCE pairs against injected crypto ports.
final class PkceFactory {
  const PkceFactory({required this.random, required this.hasher});

  final SecureRandomSource random;
  final Sha256Hasher hasher;

  /// Creates an S256 pair from 32 fresh random bytes (43-character verifier).
  PkcePair createS256() {
    final CodeVerifier verifier = CodeVerifier(
      base64UrlNoPad(random.nextBytes(32)),
    );
    return PkcePair(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// Derives the S256 challenge for an existing [verifier].
  CodeChallenge challengeFor(CodeVerifier verifier) {
    final Uint8List digest = hasher.digest(
      Uint8List.fromList(ascii.encode(verifier.value)),
    );
    return CodeChallenge(base64UrlNoPad(digest), PkceChallengeMethod.s256);
  }

  /// Verifies that [verifier] produces [challenge] under [challenge]'s method.
  /// Uses a length-safe, constant-time comparison to avoid leaking match
  /// position through timing.
  bool verify(CodeVerifier verifier, CodeChallenge challenge) {
    final String expected = switch (challenge.method) {
      PkceChallengeMethod.s256 => challengeFor(verifier).value,
      PkceChallengeMethod.plain => verifier.value,
    };
    return constantTimeEquals(expected, challenge.value);
  }
}

/// Base64url without padding, per RFC 7636 Appendix A.
String base64UrlNoPad(List<int> bytes) {
  final String encoded = base64Url.encode(bytes);
  final int pad = encoded.indexOf('=');
  return pad == -1 ? encoded : encoded.substring(0, pad);
}

/// Compares two ASCII strings in time independent of the position of the first
/// difference. Length is compared up front (lengths are not secret here).
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i += 1) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
