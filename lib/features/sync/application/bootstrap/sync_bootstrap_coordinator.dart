/// The client-side bootstrap/rebase orchestration (R-SYNC-006, data-model.md
/// §6 "Bootstrap, relink, and auth").
///
/// [SyncBootstrapCoordinator.begin] runs the normative pre-activation phases —
/// close admission, quiesce, inventory, stage, copy local-only state, rebase
/// the journal without a receipt short-circuit, import original receipts, pull
/// post-watermark changes, and verify — under the exclusive maintenance gate,
/// then hands back a paused [BootstrapSession]. Command admission stays closed
/// through the whole session and reopens only after [BootstrapSession.activate]
/// atomically switches the generation, or after [BootstrapSession.cancel]
/// discards the staged generation without touching the live one.
///
/// The identical flow serves both a second device's staged merge and a
/// stale-epoch rebase; only the [BootstrapTrigger] differs.
library;

// Named constructor parameters use public names bound to private fields; the
// initializing-formal form would leak underscored parameter names into the API.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

/// Orchestrates bootstraps. Stateless and reusable; each [begin] returns an
/// independent [BootstrapSession].
final class SyncBootstrapCoordinator {
  const SyncBootstrapCoordinator({
    required MaintenanceGate gate,
    required LocalGenerationInventory inventory,
    required StagedGenerationBuilder stagedBuilder,
    required PendingCommandRebaser rebaser,
    required RemoteBootstrapGateway gateway,
    required BootstrapManifestVerifier verifier,
  }) : _gate = gate,
       _inventory = inventory,
       _stagedBuilder = stagedBuilder,
       _rebaser = rebaser,
       _gateway = gateway,
       _verifier = verifier;

  final MaintenanceGate _gate;
  final LocalGenerationInventory _inventory;
  final StagedGenerationBuilder _stagedBuilder;
  final PendingCommandRebaser _rebaser;
  final RemoteBootstrapGateway _gateway;
  final BootstrapManifestVerifier _verifier;

  /// Runs every pre-activation phase under the maintenance gate and returns a
  /// paused session ready to activate or cancel.
  ///
  /// On any failure the staged generation (if built) is discarded and command
  /// admission is reopened; the live generation is never touched, and a
  /// [BootstrapException] is thrown as a Recovery-Mode signal.
  Future<BootstrapSession> begin({
    required ProfileId profile,
    required RemoteProfileId remoteProfileId,
    required int serverEpoch,
    required int watermark,
    required BootstrapTrigger trigger,
  }) async {
    BootstrapPhase current = BootstrapPhase.closeAdmission;
    StagedGeneration? staged;
    try {
      await _gate.closeAdmission();

      current = BootstrapPhase.awaitActiveTransactions;
      await _gate.awaitActiveTransactions();

      current = BootstrapPhase.settleSyncWorkers;
      await _gate.settleSyncWorkers();

      current = BootstrapPhase.inventory;
      final LocalInventory inventory = await _inventory.inventory(profile);

      current = BootstrapPhase.buildStaging;
      staged = await _stagedBuilder.build(
        profile: profile,
        baseEpoch: serverEpoch,
        watermark: watermark,
      );

      current = BootstrapPhase.copyLocalOnly;
      for (final LocalOnlyItem item in inventory.localOnly) {
        await staged.copyLocalOnly(item);
      }
      // Settled (non-pending-command) receipts are copied normally here; the
      // pending-command receipts are imported only after rebase so the intent
      // is not short-circuited.
      for (final ReceiptRecord receipt in inventory.settledReceipts) {
        await staged.importReceipt(receipt);
      }

      current = BootstrapPhase.rebaseJournal;
      final List<RebaseResult> rebaseResults = <RebaseResult>[];
      for (final PendingCommandRecord command in inventory.pendingCommands) {
        rebaseResults.add(
          await _rebaser.rebase(staged, command, newEpoch: serverEpoch),
        );
      }

      current = BootstrapPhase.importReceipts;
      // Stable receipt restoration: the original receipts are imported verbatim
      // after their intents rebased, so replays stay idempotent with unchanged
      // results.
      for (final ReceiptRecord receipt in inventory.pendingCommandReceipts) {
        await staged.importReceipt(receipt);
      }

      current = BootstrapPhase.pullPostWatermark;
      final List<RemoteChange> changes = await _gateway.pullPostWatermark(
        remoteProfileId: remoteProfileId,
        epoch: serverEpoch,
        watermark: watermark,
      );
      for (final RemoteChange change in changes) {
        await staged.applyPulledChange(change);
      }

      current = BootstrapPhase.verify;
      final ManifestVerification verification = await _verifier.verify(
        staged: staged,
        inventory: inventory,
      );
      if (!verification.passed) {
        throw BootstrapException(
          BootstrapPhase.verify,
          verification.firstFailure ?? 'Manifest verification failed.',
        );
      }

      return BootstrapSession._(
        gate: _gate,
        staged: staged,
        trigger: trigger,
        commitSeq: inventory.commitSeq,
        newEpoch: serverEpoch,
        rebaseResults: rebaseResults,
        localOnlyItemsPreserved: inventory.localOnly.length,
        receiptsPreserved: inventory.receipts.length,
        pulledChangeCount: changes.length,
      );
    } on BootstrapException {
      await _abort(staged);
      rethrow;
    } on Object catch (error) {
      await _abort(staged);
      throw BootstrapException(current, error.toString());
    }
  }

  Future<void> _abort(StagedGeneration? staged) async {
    if (staged != null) {
      await staged.discard();
    }
    await _gate.reopenAdmission();
  }
}

/// The lifecycle state of a [BootstrapSession].
enum BootstrapSessionState { readyToActivate, activated, cancelled }

/// A prepared bootstrap paused immediately before atomic generation
/// activation. Exactly one of [activate] or [cancel] may be called.
final class BootstrapSession {
  BootstrapSession._({
    required MaintenanceGate gate,
    required StagedGeneration staged,
    required this.trigger,
    required int commitSeq,
    required int newEpoch,
    required List<RebaseResult> rebaseResults,
    required int localOnlyItemsPreserved,
    required int receiptsPreserved,
    required int pulledChangeCount,
  }) : _gate = gate,
       _staged = staged,
       _commitSeq = commitSeq,
       _newEpoch = newEpoch,
       _rebaseResults = List<RebaseResult>.unmodifiable(rebaseResults),
       _localOnlyItemsPreserved = localOnlyItemsPreserved,
       _receiptsPreserved = receiptsPreserved,
       _pulledChangeCount = pulledChangeCount;

  final MaintenanceGate _gate;
  final StagedGeneration _staged;
  final BootstrapTrigger trigger;
  final int _commitSeq;
  final int _newEpoch;
  final List<RebaseResult> _rebaseResults;
  final int _localOnlyItemsPreserved;
  final int _receiptsPreserved;
  final int _pulledChangeCount;

  BootstrapSessionState _state = BootstrapSessionState.readyToActivate;

  BootstrapSessionState get state => _state;

  /// The rebase effects computed for the pending commands (a preview a staged
  /// merge can present before deciding to activate).
  List<RebaseResult> get rebaseResults => _rebaseResults;

  int get newEpochGroupCount => _rebaseResults
      .where((RebaseResult r) => r.effect == RebaseEffect.newEpochGroup)
      .length;

  int get durableConflictCount => _rebaseResults
      .where((RebaseResult r) => r.effect == RebaseEffect.durableConflict)
      .length;

  /// Atomically activates the staged generation and reopens command admission.
  ///
  /// The generation switch is atomic (old-or-new, never partial: NFR-REL-002).
  /// If it fails, the prior generation stays live, so the staged generation is
  /// discarded and command admission is reopened — never left wedged in
  /// maintenance — before a [BootstrapException] surfaces the failure as a
  /// Recovery-Mode signal (R-SYNC-006).
  Future<BootstrapReport> activate() async {
    _requireReady();
    try {
      await _staged.activate();
    } on Object catch (error) {
      _state = BootstrapSessionState.cancelled;
      await _staged.discard();
      await _gate.reopenAdmission();
      throw BootstrapException(BootstrapPhase.activate, error.toString());
    }
    _state = BootstrapSessionState.activated;
    await _gate.reopenAdmission();
    return BootstrapReport(
      trigger: trigger,
      commitSeq: _commitSeq,
      newEpoch: _newEpoch,
      rebaseResults: _rebaseResults,
      localOnlyItemsPreserved: _localOnlyItemsPreserved,
      receiptsPreserved: _receiptsPreserved,
      pulledChangeCount: _pulledChangeCount,
    );
  }

  /// Discards the staged generation without touching the live one and reopens
  /// command admission (R-SYNC-001 cancel).
  Future<void> cancel() async {
    _requireReady();
    await _staged.discard();
    _state = BootstrapSessionState.cancelled;
    await _gate.reopenAdmission();
  }

  void _requireReady() {
    if (_state != BootstrapSessionState.readyToActivate) {
      throw StateError(
        'Bootstrap session already resolved (state=${_state.name}).',
      );
    }
  }
}
