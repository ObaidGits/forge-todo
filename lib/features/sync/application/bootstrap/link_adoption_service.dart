/// The client-side link/adoption lifecycle (R-SYNC-001, R-SYNC-006,
/// R-SYNC-008; data-model.md §6 "Bootstrap, relink, and auth").
///
/// This service composes the bootstrap coordinator, the remote gateway, the
/// link store, and the auth session into the end-to-end flows a device uses to
/// bind to a remote profile:
///
///  * [preview] compares local and remote without mutating anything and offers
///    create-remote, staged-merge, or cancel;
///  * [createRemoteProfile] performs first-device adoption — the remote profile
///    adopts the creating device's local profile id;
///  * [stageMerge] stages a second device's merge into a shadow generation that
///    can be [StagedMergeHandle.confirm]ed or [StagedMergeHandle.cancel]led
///    without touching the live generation;
///  * [bootstrapStaleEpoch] rebases a stale device onto the server's epoch;
///  * [signOut] retains local data while revoking tokens; and
///  * [requestRemoteDelete] gates remote deletion behind recent
///    reauthentication.
///
/// Entity IDs are never rekeyed and a collision/ambiguity aborts without local
/// mutation (R-SYNC-001).
library;

// Named constructor parameters use public names bound to private fields; the
// initializing-formal form would leak underscored parameter names into the API.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/application/bootstrap/sync_bootstrap_coordinator.dart';
import 'package:forge/features/sync/application/bootstrap/sync_trust_gate.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

/// Raised when a link/adoption operation cannot proceed without mutating state
/// — an account swap, an ownership collision, or a wrong-path request
/// (R-SYNC-001 "collision or ambiguity fails without local mutation").
final class LinkAdoptionException implements Exception {
  const LinkAdoptionException(this.reason);

  final String reason;

  @override
  String toString() => 'LinkAdoptionException: $reason';
}

/// The outcome of a remote-delete request.
enum RemoteDeleteOutcome {
  /// The remote profile was deleted (recent reauthentication was present).
  deleted,

  /// Deletion was refused pending recent reauthentication; the session is now
  /// in `remote_delete_reauth`.
  reauthenticationRequired,
}

/// A staged second-device merge paused before activation. Confirming activates
/// the merged generation and records the link; cancelling discards the shadow
/// generation and leaves the device unlinked with its live generation intact.
final class StagedMergeHandle {
  StagedMergeHandle._({
    required BootstrapSession session,
    required SyncProfileLink pendingLink,
    required SyncProfileLinkStore linkStore,
    required AuthSessionController auth,
  }) : _session = session,
       _pendingLink = pendingLink,
       _linkStore = linkStore,
       _auth = auth;

  final BootstrapSession _session;
  final SyncProfileLink _pendingLink;
  final SyncProfileLinkStore _linkStore;
  final AuthSessionController _auth;

  /// The staged merge's rebase preview (new-epoch group and conflict counts)
  /// the UI can present before the user confirms.
  int get newEpochGroupCount => _session.newEpochGroupCount;

  int get durableConflictCount => _session.durableConflictCount;

  /// The remote profile the second device would link to on confirmation.
  RemoteProfileId get remoteProfileId => _pendingLink.remoteProfileId;

  /// Activates the merged generation and records the durable link.
  Future<BootstrapReport> confirm() async {
    final BootstrapReport report = await _session.activate();
    await _linkStore.save(_pendingLink);
    _auth.bindLinked(true);
    return report;
  }

  /// Discards the shadow generation; the live generation is untouched and no
  /// link is recorded.
  Future<void> cancel() async {
    await _session.cancel();
    _auth.bindLinked(false);
  }
}

/// Orchestrates linking, adoption, staged merge, stale-epoch bootstrap,
/// sign-out, and remote-delete reauthentication.
final class LinkAdoptionService {
  LinkAdoptionService({
    required SyncBootstrapCoordinator coordinator,
    required RemoteBootstrapGateway gateway,
    required SyncProfileLinkStore linkStore,
    required LocalManifestDigestSource localDigest,
    required AuthSessionController auth,
    RemoteProfileDeleter? remoteDeleter,
    SyncTrustGate? trustGate,
  }) : _coordinator = coordinator,
       _gateway = gateway,
       _linkStore = linkStore,
       _localDigest = localDigest,
       _auth = auth,
       _remoteDeleter = remoteDeleter,
       _trustGate = trustGate;

  final SyncBootstrapCoordinator _coordinator;
  final RemoteBootstrapGateway _gateway;
  final SyncProfileLinkStore _linkStore;
  final LocalManifestDigestSource _localDigest;
  final AuthSessionController _auth;
  final RemoteProfileDeleter? _remoteDeleter;

  /// The trust-model precondition gate. When present, a device may only create
  /// or merge a remote profile after the TLS/non-E2EE disclosure has been
  /// acknowledged and the target backend validated (R-SYNC-007, NFR-SEC-002).
  /// It is optional so identity/bootstrap unit tests can exercise the flow in
  /// isolation; production composition always supplies it.
  final SyncTrustGate? _trustGate;

  /// Compares local and remote state and offers the three explicit options.
  /// Never mutates local or remote state.
  Future<LinkPreview> preview({
    required OwnerUserId owner,
    required ProfileId localProfile,
    required String backend,
  }) async {
    await _guardNoAccountSwap(
      owner: owner,
      localProfile: localProfile,
      backend: backend,
    );
    final ManifestDigest local = await _localDigest.localDigest(localProfile);
    final RemoteProfileSnapshot? remote = await _gateway.lookupRemoteProfile(
      owner,
    );
    if (remote == null) {
      return LinkPreview.noRemoteProfile(localDigest: local);
    }
    return LinkPreview.existingRemoteProfile(
      localDigest: local,
      remoteDigest: remote.digest,
    );
  }

  /// First-device adoption + remote creation. The remote profile adopts the
  /// creating device's local profile id; entity IDs never change.
  Future<SyncProfileLink> createRemoteProfile({
    required OwnerUserId owner,
    required ProfileId localProfile,
    required String backend,
  }) async {
    await _guardNoAccountSwap(
      owner: owner,
      localProfile: localProfile,
      backend: backend,
    );
    await _assertTrustGate(backend);
    final RemoteProfileSnapshot? existing = await _gateway.lookupRemoteProfile(
      owner,
    );
    if (existing != null) {
      throw const LinkAdoptionException(
        'A remote profile already exists for this account; use a staged '
        'merge rather than creating a new one.',
      );
    }
    final SyncProfileLink link = SyncProfileLink(
      localProfileId: localProfile,
      backend: backend,
      ownerUserId: owner,
      // The remote profile adopts the creating device's local profile id.
      remoteProfileId: RemoteProfileId(localProfile.value),
      state: SyncLinkState.linked,
    );
    await _linkStore.save(link);
    _auth.bindLinked(true);
    return link;
  }

  /// Stages a second device's merge into a shadow generation and returns a
  /// handle to confirm or cancel it. Command admission stays closed for the
  /// life of the returned handle until it is confirmed or cancelled.
  Future<StagedMergeHandle> stageMerge({
    required OwnerUserId owner,
    required ProfileId localProfile,
    required String backend,
  }) async {
    await _guardNoAccountSwap(
      owner: owner,
      localProfile: localProfile,
      backend: backend,
    );
    await _assertTrustGate(backend);
    final RemoteProfileSnapshot? remote = await _gateway.lookupRemoteProfile(
      owner,
    );
    if (remote == null) {
      throw const LinkAdoptionException(
        'No remote profile exists for this account; create one instead of '
        'merging.',
      );
    }
    final BootstrapSession session = await _coordinator.begin(
      profile: localProfile,
      remoteProfileId: remote.remoteProfileId,
      serverEpoch: remote.epoch,
      watermark: remote.watermark,
      trigger: BootstrapTrigger.stagedMerge,
    );
    // The second device keeps its own local id and records a link to the
    // account's existing remote profile (R-SYNC-001).
    final SyncProfileLink pendingLink = SyncProfileLink(
      localProfileId: localProfile,
      backend: backend,
      ownerUserId: owner,
      remoteProfileId: remote.remoteProfileId,
      state: SyncLinkState.linked,
    );
    return StagedMergeHandle._(
      session: session,
      pendingLink: pendingLink,
      linkStore: _linkStore,
      auth: _auth,
    );
  }

  /// Rebases a stale-epoch device onto the server's current epoch. Unlike a
  /// staged merge this activates immediately — there is no cancel path once a
  /// push has been rejected for a stale epoch.
  Future<BootstrapReport> bootstrapStaleEpoch({
    required ProfileId localProfile,
  }) async {
    final SyncProfileLink? link = await _linkStore.read(localProfile);
    if (link == null || !link.state.canExchange) {
      throw const LinkAdoptionException(
        'A stale-epoch bootstrap requires an active linked profile.',
      );
    }
    final RemoteProfileSnapshot? remote = await _gateway.lookupRemoteProfile(
      link.ownerUserId,
    );
    if (remote == null) {
      throw const LinkAdoptionException(
        'The linked remote profile no longer exists.',
      );
    }
    final BootstrapSession session = await _coordinator.begin(
      profile: localProfile,
      remoteProfileId: remote.remoteProfileId,
      serverEpoch: remote.epoch,
      watermark: remote.watermark,
      trigger: BootstrapTrigger.staleEpoch,
    );
    return session.activate();
  }

  /// Signs out, retaining local data (R-SYNC-008). Tokens are revoked and the
  /// link is marked signed-out; local records are never deleted here. Returns
  /// the caller's retain-local choice for the data owner to act on.
  Future<Result<bool>> signOut({
    required ProfileId localProfile,
    required bool retainLocalData,
  }) async {
    final Result<bool> result = await _auth.signOut(
      retainLocalData: retainLocalData,
    );
    final SyncProfileLink? link = await _linkStore.read(localProfile);
    if (link != null) {
      await _linkStore.save(link.copyWith(state: SyncLinkState.signedOut));
    }
    return result;
  }

  /// Requests remote deletion. It is refused unless the account reauthenticated
  /// recently; on refusal the session enters `remote_delete_reauth`
  /// (R-SYNC-008, data-model.md §6).
  Future<RemoteDeleteOutcome> requestRemoteDelete({
    required ProfileId localProfile,
  }) async {
    if (!_auth.hasRecentReauthentication) {
      _auth.requireRemoteDeleteReauth();
      return RemoteDeleteOutcome.reauthenticationRequired;
    }
    final SyncProfileLink? link = await _linkStore.read(localProfile);
    if (link == null) {
      throw const LinkAdoptionException('No linked remote profile to delete.');
    }
    final RemoteProfileDeleter? deleter = _remoteDeleter;
    if (deleter == null) {
      throw const LinkAdoptionException(
        'No remote-profile deleter is configured.',
      );
    }
    await deleter.deleteRemoteProfile(link.remoteProfileId);
    // Remote deletion unlinks locally but never deletes local records; the
    // retained local/other-device copies are communicated by the caller.
    await _linkStore.save(link.copyWith(state: SyncLinkState.signedOut));
    _auth.bindLinked(false);
    return RemoteDeleteOutcome.deleted;
  }

  /// Enforces the trust-model precondition before a mutating link. When a gate
  /// is configured, the TLS/non-E2EE disclosure must be acknowledged and the
  /// backend validated; a failure surfaces as a [LinkAdoptionException] so the
  /// link flow aborts without mutation (R-SYNC-007, NFR-SEC-002).
  Future<void> _assertTrustGate(String backend) async {
    final SyncTrustGate? gate = _trustGate;
    if (gate == null) {
      return;
    }
    try {
      await gate.assertReadyToLink(backend);
    } on SyncTrustGateException catch (error) {
      throw LinkAdoptionException(error.reason);
    }
  }

  /// Fails a link operation when the local profile is already linked to a
  /// different account (an account swap must unlink and re-preview first).
  Future<void> _guardNoAccountSwap({
    required OwnerUserId owner,
    required ProfileId localProfile,
    required String backend,
  }) async {
    final SyncProfileLink? existing = await _linkStore.read(localProfile);
    if (existing == null) {
      return;
    }
    if (existing.backend == backend &&
        existing.ownerUserId != owner &&
        existing.state != SyncLinkState.signedOut) {
      throw const LinkAdoptionException(
        'This profile is linked to a different account; unlink before '
        'previewing a new link.',
      );
    }
  }
}
