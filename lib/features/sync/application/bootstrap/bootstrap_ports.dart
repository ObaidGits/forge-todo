/// Integration-boundary ports the bootstrap/adoption orchestration composes
/// (R-SYNC-001, R-SYNC-006, R-SYNC-008; design.md §12, data-model.md §6).
///
/// The orchestration in this package is pure application glue: it sequences the
/// normative bootstrap phases and enforces the invariants, but delegates every
/// side effect (maintenance gating, generation staging/activation, journal
/// rebase, remote pull, manifest verification, link persistence) to one of
/// these replaceable ports. The concrete adapters — which reuse the existing
/// `DatabaseRuntime` writer-lock/maintenance machinery, the shadow-generation +
/// `ActiveGenerationPointer` activation path, and the journal/outbox/receipt
/// repositories — are wired at the composition root. Tests exercise the
/// orchestration with deterministic in-memory fakes.
library;

import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

/// The exclusive maintenance gate that gates command admission for the whole
/// bootstrap (R-SYNC-006). A real adapter maps onto the `DatabaseRuntime`
/// maintenance state and writer lock; it never forks that machinery.
abstract interface class MaintenanceGate {
  /// Admits (or rejects) a new local command. While the gate is closed, this
  /// returns a *retryable* maintenance failure so the caller retries after the
  /// bootstrap completes rather than losing the command.
  Result<void> admit();

  /// Acquires the exclusive maintenance gate and closes command admission.
  Future<void> closeAdmission();

  /// Awaits all active local transactions to settle.
  Future<void> awaitActiveTransactions();

  /// Stops and settles sync workers so none races the inventory.
  Future<void> settleSyncWorkers();

  /// Reopens command admission after activation or a cancel.
  Future<void> reopenAdmission();

  /// Whether new commands are currently admitted.
  bool get isAdmitting;
}

/// Snapshots the active local generation at one `commit_seq` and inventories
/// the state a bootstrap must preserve (R-SYNC-006).
abstract interface class LocalGenerationInventory {
  Future<LocalInventory> inventory(ProfileId profile);
}

/// A draft of a new-epoch outbox group produced by rebasing one pending
/// command against the staged base.
final class StagedGroupDraft {
  StagedGroupDraft({
    required this.groupId,
    required this.epoch,
    required this.entityType,
    required this.entityId,
    required this.newRowVersion,
    required this.canonicalPayload,
  });

  final String groupId;
  final int epoch;
  final String entityType;
  final String entityId;
  final int newRowVersion;
  final String canonicalPayload;
}

/// A draft of a durable conflict artifact produced when a rebased intent
/// collided with server-accepted state on the staged base.
final class StagedConflictDraft {
  StagedConflictDraft({
    required this.artifactId,
    required this.entityType,
    required this.entityId,
    required this.baseRowVersion,
    required this.stagedRowVersion,
  });

  final String artifactId;
  final String entityType;
  final String entityId;
  final int? baseRowVersion;
  final int stagedRowVersion;
}

/// The unexposed generation a bootstrap builds and then either activates
/// atomically or discards. A real adapter builds a complete shadow generation
/// directory and activates it through the single `ActiveGenerationPointer`
/// switch (design.md §12); it is never the live generation until [activate].
abstract interface class StagedGeneration {
  /// The snapshot epoch this staged generation is being built at.
  int get epoch;

  /// The staged row version for an entity, or null when the staged base has no
  /// row for it yet.
  Future<int?> stagedVersionOf(String entityType, String entityId);

  /// Copies one verified local-only item into staging (R-SYNC-006 "copies
  /// verified local-only state").
  Future<void> copyLocalOnly(LocalOnlyItem item);

  /// Imports one durable receipt unchanged (stable receipt restoration).
  Future<void> importReceipt(ReceiptRecord receipt);

  /// Records a rebased intent as a new-epoch outbox group and advances the
  /// staged row version accordingly.
  Future<void> recordNewEpochGroup(StagedGroupDraft group);

  /// Records a rebased intent that collided as a durable conflict artifact.
  Future<void> recordDurableConflict(StagedConflictDraft conflict);

  /// Applies one post-watermark pulled change into staging.
  Future<void> applyPulledChange(RemoteChange change);

  /// Atomically activates this staged generation as the live one.
  Future<void> activate();

  /// Discards this staged generation without touching the live one.
  Future<void> discard();
}

/// Builds an unexposed [StagedGeneration] for a bootstrap.
abstract interface class StagedGenerationBuilder {
  Future<StagedGeneration> build({
    required ProfileId profile,
    required int baseEpoch,
    required int watermark,
  });
}

/// Replays one pending command's journaled intent against the staged base
/// *without* consulting its receipt, then classifies the effect (R-SYNC-006).
abstract interface class PendingCommandRebaser {
  Future<RebaseResult> rebase(
    StagedGeneration staged,
    PendingCommandRecord command, {
    required int newEpoch,
  });
}

/// A snapshot of the account's existing remote profile, used for both link
/// preview and bootstrap.
final class RemoteProfileSnapshot {
  RemoteProfileSnapshot({
    required this.remoteProfileId,
    required this.ownerUserId,
    required this.epoch,
    required this.watermark,
    required this.digest,
  });

  final RemoteProfileId remoteProfileId;
  final OwnerUserId ownerUserId;
  final int epoch;
  final int watermark;
  final ManifestDigest digest;
}

/// The server-facing gateway a bootstrap uses to look up the account's remote
/// profile and pull post-watermark changes. It is a thin, replaceable seam over
/// the transport; nothing here speaks the wire protocol directly.
abstract interface class RemoteBootstrapGateway {
  /// Returns the account's existing remote profile, or null when none exists
  /// (which routes a preview to "create remote").
  Future<RemoteProfileSnapshot?> lookupRemoteProfile(OwnerUserId owner);

  /// Pulls the post-watermark changes for the linked remote profile.
  Future<List<RemoteChange>> pullPostWatermark({
    required RemoteProfileId remoteProfileId,
    required int epoch,
    required int watermark,
  });
}

/// The outcome of verifying the staged generation's manifests before
/// activation.
final class ManifestVerification {
  ManifestVerification.passed() : passed = true, firstFailure = null;

  ManifestVerification.failed(String reason)
    : passed = false,
      firstFailure = reason;

  final bool passed;
  final String? firstFailure;
}

/// Verifies both the remote and preserved-local manifests of a staged
/// generation before it is activated (R-SYNC-006).
abstract interface class BootstrapManifestVerifier {
  Future<ManifestVerification> verify({
    required StagedGeneration staged,
    required LocalInventory inventory,
  });
}

/// Durable persistence for the `(local_profile_id, owner_user_id,
/// remote_profile_id)` link (data-model.md §3 `sync_profile_links`).
abstract interface class SyncProfileLinkStore {
  Future<SyncProfileLink?> read(ProfileId localProfile);

  Future<void> save(SyncProfileLink link);

  Future<void> delete(ProfileId localProfile);
}

/// Computes the local generation's replicated [ManifestDigest] for a link
/// preview (counts + root hash over replicated content). Pure/read-only.
abstract interface class LocalManifestDigestSource {
  Future<ManifestDigest> localDigest(ProfileId profile);
}

/// Deletes the account's remote profile. Remote deletion is separate from
/// sign-out and requires recent reauthentication (R-SYNC-008); the caller
/// enforces the reauthentication gate before invoking this port.
abstract interface class RemoteProfileDeleter {
  Future<void> deleteRemoteProfile(RemoteProfileId remoteProfileId);
}

/// The narrow slice of the auth state machine the adoption flow drives
/// (R-SYNC-001, R-SYNC-008). The concrete Supabase state machine from task 9.4
/// is adapted onto this port so the adoption service stays testable with a
/// deterministic fake and does not depend on the full auth wiring.
abstract interface class AuthSessionController {
  /// Records whether a durable profile link now exists so the auth status
  /// projects `linked` vs `link_preview`.
  void bindLinked(bool linked);

  /// Whether the account reauthenticated recently enough to permit remote
  /// deletion.
  bool get hasRecentReauthentication;

  /// Moves the session into the `remote_delete_reauth` state.
  void requireRemoteDeleteReauth();

  /// Signs out: revokes tokens without deleting local records; the returned
  /// value echoes the caller's retain-local choice (R-SYNC-008).
  Future<Result<bool>> signOut({required bool retainLocalData});
}
