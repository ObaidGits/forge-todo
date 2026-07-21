/// The ordered phases of a bootstrap/rebase and the results it produces
/// (R-SYNC-006, data-model.md §6).
///
/// The phase order is normative: the exclusive maintenance gate is acquired and
/// command admission closed *before* anything is inventoried, and admission
/// stays closed through post-watermark pull, verification, and atomic
/// generation activation — it reopens only after activation (or after a cancel
/// that discards the staged generation without touching the live one).
library;

/// What initiated a bootstrap. Both paths run the identical R-SYNC-006 flow.
enum BootstrapTrigger {
  /// A second device is linking to an existing remote profile via a staged
  /// merge that can be cancelled.
  stagedMerge,

  /// A push was rejected because the device's snapshot epoch is stale; the
  /// device must rebase onto the server's epoch before it may push again.
  staleEpoch,
}

/// The normative, ordered phases of a bootstrap.
enum BootstrapPhase {
  /// Acquire the exclusive maintenance gate and reject new command admission
  /// with a retryable maintenance result.
  closeAdmission,

  /// Await all active local transactions to settle.
  awaitActiveTransactions,

  /// Stop and settle sync workers so no work races the inventory.
  settleSyncWorkers,

  /// Snapshot the active generation at one `commit_seq` and inventory
  /// local-only rows/files, all receipts, and every pending command's journal.
  inventory,

  /// Build the unexposed remote generation in staging.
  buildStaging,

  /// Copy verified local-only state (and settled receipts) into staging,
  /// excluding pending-command receipts.
  copyLocalOnly,

  /// Rebase pending commands in commit order without a receipt short-circuit.
  rebaseJournal,

  /// Import the original pending-command receipts unchanged (stable receipts).
  importReceipts,

  /// Pull post-watermark changes into staging.
  pullPostWatermark,

  /// Verify remote and preserved-local manifests before activation.
  verify,

  /// Atomically activate the staged generation.
  activate,

  /// Reopen command admission after activation (or after a cancel).
  reopenAdmission,
}

/// The effect a single pending command's rebase produced.
enum RebaseEffect {
  /// The journaled intent applied cleanly against the staged base and created a
  /// new-epoch outbox group.
  newEpochGroup,

  /// The journaled intent collided with server-accepted state and was preserved
  /// as a durable conflict artifact.
  durableConflict,
}

/// The result of rebasing one pending command. The command's original stable
/// result is echoed unchanged — a rebase never rewrites a committed result.
final class RebaseResult {
  RebaseResult({
    required this.commandId,
    required this.effect,
    required this.stableResultCode,
    required this.stablePayloadVersion,
    this.newGroupId,
    this.conflictArtifactId,
  }) {
    switch (effect) {
      case RebaseEffect.newEpochGroup:
        if (newGroupId == null) {
          throw ArgumentError(
            'A new-epoch group rebase must carry a group id.',
          );
        }
      case RebaseEffect.durableConflict:
        if (conflictArtifactId == null) {
          throw ArgumentError(
            'A durable-conflict rebase must carry a conflict artifact id.',
          );
        }
    }
  }

  final String commandId;
  final RebaseEffect effect;

  /// The command's original result code, echoed unchanged.
  final String stableResultCode;

  /// The command's original payload version, echoed unchanged.
  final int stablePayloadVersion;

  final String? newGroupId;
  final String? conflictArtifactId;
}

/// A summary of a completed (activated) bootstrap.
final class BootstrapReport {
  BootstrapReport({
    required this.trigger,
    required this.commitSeq,
    required this.newEpoch,
    required Iterable<RebaseResult> rebaseResults,
    required this.localOnlyItemsPreserved,
    required this.receiptsPreserved,
    required this.pulledChangeCount,
  }) : rebaseResults = List<RebaseResult>.unmodifiable(rebaseResults);

  final BootstrapTrigger trigger;
  final int commitSeq;
  final int newEpoch;
  final List<RebaseResult> rebaseResults;
  final int localOnlyItemsPreserved;
  final int receiptsPreserved;
  final int pulledChangeCount;

  int get newEpochGroupCount => rebaseResults
      .where((RebaseResult r) => r.effect == RebaseEffect.newEpochGroup)
      .length;

  int get durableConflictCount => rebaseResults
      .where((RebaseResult r) => r.effect == RebaseEffect.durableConflict)
      .length;
}

/// Raised when a bootstrap fails. The prior generation remains live and
/// untouched; this is a Recovery-Mode signal, never a trigger to reset data.
final class BootstrapException implements Exception {
  const BootstrapException(this.phase, this.reason);

  /// The phase that was executing when the failure occurred.
  final BootstrapPhase phase;
  final String reason;

  @override
  String toString() => 'BootstrapException(${phase.name}: $reason)';
}
