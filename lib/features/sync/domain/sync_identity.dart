/// Account/profile-link identity model and the local↔remote translation that
/// `SyncTransport` performs at the wire boundary (R-SYNC-001, design.md §8,
/// data-model.md §6).
///
/// A device keeps its local `profile_id` forever; entity IDs are never rekeyed.
/// One authenticated account binds to at most one Forge remote sync profile.
/// The client stores an explicit `(local_profile_id, owner_user_id,
/// remote_profile_id)` link. Wire envelopes use `remote_profile_id`; local
/// repositories, receipts, cursors, conflicts, and events keep the local
/// `profile_id`.
library;

import 'package:forge/core/domain/id.dart';

/// The authenticated account subject that owns a remote profile. Derived by the
/// server from authentication; the client stores it in the link row so it can
/// detect account swaps (R-SYNC-001 `account_changed`).
final class OwnerUserId extends ForgeId {
  OwnerUserId(String value) : super(ForgeId.validate(value, 'OwnerUserId'));
}

/// The remote profile identifier used on the wire. When the creating device
/// links first, the remote profile adopts the creating device's local profile
/// ID; a second device keeps its own local ID and records a link to this remote
/// profile (R-SYNC-001).
final class RemoteProfileId extends ForgeId {
  RemoteProfileId(String value)
    : super(ForgeId.validate(value, 'RemoteProfileId'));
}

/// The lifecycle state of an account/profile link (R-SYNC-001 auth states).
enum SyncLinkState {
  /// No account is bound; sync is inert and local-first behavior is unchanged.
  signedOut,

  /// A redirect auth flow is in progress (PKCE/state/nonce).
  authenticating,

  /// Counts/manifests/root hashes are being compared before adoption or merge.
  linkPreview,

  /// The account is bound to a remote profile and sync may push/pull.
  linked,

  /// The session expired; refresh or reauthentication is required.
  expired,

  /// The device was revoked server-side; it must reauthenticate.
  revoked,

  /// A different account signed in; unlink/preview is required before sync.
  accountChanged,

  /// Remote deletion was requested and requires recent reauthentication.
  remoteDeleteReauth;

  /// Only a fully `linked` account may translate identity and exchange data.
  bool get canExchange => this == SyncLinkState.linked;
}

/// A durable `(local_profile_id, owner_user_id, remote_profile_id)` link
/// (data-model.md §3 `sync_profile_links`). Immutable value object; the
/// repository owns persistence.
final class SyncProfileLink {
  SyncProfileLink({
    required this.localProfileId,
    required this.backend,
    required this.ownerUserId,
    required this.remoteProfileId,
    required this.state,
    this.accountFingerprint,
  }) {
    if (backend.isEmpty) {
      throw ArgumentError.value(backend, 'backend', 'Must not be empty.');
    }
  }

  final ProfileId localProfileId;

  /// The backend identifier (e.g. a hosted or self-hosted Supabase instance);
  /// a compatible future service reuses this contract (R-SYNC-007).
  final String backend;

  final OwnerUserId ownerUserId;
  final RemoteProfileId remoteProfileId;
  final SyncLinkState state;

  /// Opaque account fingerprint used to detect account swaps (R-SYNC-001).
  final String? accountFingerprint;

  SyncProfileLink copyWith({
    SyncLinkState? state,
    String? accountFingerprint,
  }) => SyncProfileLink(
    localProfileId: localProfileId,
    backend: backend,
    ownerUserId: ownerUserId,
    remoteProfileId: remoteProfileId,
    state: state ?? this.state,
    accountFingerprint: accountFingerprint ?? this.accountFingerprint,
  );
}

/// Raised when identity translation cannot proceed because no active link
/// exists, the link is not exchangeable, or a wire envelope references a
/// profile outside the linked remote profile (a forged/foreign reference).
final class SyncIdentityException implements Exception {
  const SyncIdentityException(this.reason);

  final String reason;

  @override
  String toString() => 'SyncIdentityException: $reason';
}

/// Translates between the local `profile_id` and the wire `remote_profile_id`
/// against the single active link (R-SYNC-001, data-model.md §6).
///
/// * [localToRemote] runs before serialization: it maps this device's local
///   profile to the remote profile ID the wire uses. A local profile that is
///   not the linked local profile is rejected — a device never serializes
///   another profile's data.
/// * [remoteToLocal] runs on inbound envelopes/changes before typed appliers
///   run: it rejects any `remote_profile_id` other than the linked one (a
///   forged or foreign reference) and maps the linked remote profile back to
///   the existing local `profile_id`. A second device with a *different* local
///   ID than the remote profile ID still translates correctly because the
///   mapping is by link, not by value equality.
final class SyncIdentityTranslator {
  const SyncIdentityTranslator(this.link);

  /// The active link, or null when signed out.
  final SyncProfileLink? link;

  SyncProfileLink get _active {
    final SyncProfileLink? current = link;
    if (current == null) {
      throw const SyncIdentityException('No active sync profile link.');
    }
    if (!current.state.canExchange) {
      throw SyncIdentityException(
        'Link is not exchangeable (state=${current.state.name}).',
      );
    }
    return current;
  }

  /// Maps a local profile to the wire remote profile before serialization.
  RemoteProfileId localToRemote(ProfileId local) {
    final SyncProfileLink current = _active;
    if (local != current.localProfileId) {
      throw SyncIdentityException(
        'Refusing to serialize a profile that is not the linked local '
        'profile: ${local.value}.',
      );
    }
    return current.remoteProfileId;
  }

  /// Maps an inbound wire remote profile back to the existing local profile,
  /// rejecting any reference outside the linked remote profile.
  ProfileId remoteToLocal(RemoteProfileId remote) {
    final SyncProfileLink current = _active;
    if (remote != current.remoteProfileId) {
      throw SyncIdentityException(
        'Rejecting a remote profile reference outside the linked profile: '
        '${remote.value}.',
      );
    }
    return current.localProfileId;
  }
}
