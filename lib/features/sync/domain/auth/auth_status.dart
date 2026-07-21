/// The authentication phase of the redirect auth machine and its projection
/// onto the sync link state machine (R-SYNC-001 auth states).
///
/// The auth machine owns the *authentication* lifecycle (signed out, in-flight
/// redirect, an active token session, expiry, revocation, account swap, and
/// reauthentication for remote delete). Whether an active session is presented
/// as `link_preview` (authenticated but not yet bound to a remote profile) or
/// `linked` (bound) depends on the profile link, which task 9.5 owns — so the
/// projection takes a [hasLink] input rather than deciding linking itself.
library;

import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

enum AuthPhase {
  /// No account is authenticated.
  signedOut,

  /// A redirect authorization request is in flight (PKCE/state/nonce issued).
  authenticating,

  /// A valid token session exists.
  authenticated,

  /// The session expired and requires refresh or reauthentication.
  expired,

  /// The device/session was revoked server-side; reauthentication is required.
  revoked,

  /// A different account authenticated; unlink/preview is required.
  accountChanged,

  /// Remote deletion was requested and needs recent reauthentication.
  remoteDeleteReauth,
}

/// An immutable snapshot of the auth machine.
final class AuthStatus {
  const AuthStatus({
    required this.phase,
    required this.hasLink,
    this.accountFingerprint,
  });

  factory AuthStatus.signedOut() =>
      const AuthStatus(phase: AuthPhase.signedOut, hasLink: false);

  final AuthPhase phase;

  /// Whether a durable profile link already exists for this account.
  final bool hasLink;

  /// The authenticated account fingerprint, when known.
  final AccountFingerprint? accountFingerprint;

  /// Projects the auth phase onto the sync link state (R-SYNC-001). An active
  /// session with no link is `link_preview`; with a link it is `linked`.
  SyncLinkState get syncLinkState => switch (phase) {
    AuthPhase.signedOut => SyncLinkState.signedOut,
    AuthPhase.authenticating => SyncLinkState.authenticating,
    AuthPhase.authenticated =>
      hasLink ? SyncLinkState.linked : SyncLinkState.linkPreview,
    AuthPhase.expired => SyncLinkState.expired,
    AuthPhase.revoked => SyncLinkState.revoked,
    AuthPhase.accountChanged => SyncLinkState.accountChanged,
    AuthPhase.remoteDeleteReauth => SyncLinkState.remoteDeleteReauth,
  };

  AuthStatus copyWith({
    AuthPhase? phase,
    bool? hasLink,
    AccountFingerprint? accountFingerprint,
  }) => AuthStatus(
    phase: phase ?? this.phase,
    hasLink: hasLink ?? this.hasLink,
    accountFingerprint: accountFingerprint ?? this.accountFingerprint,
  );
}
