/// The reference [PendingCommandRebaser]: it replays a pending command's
/// journaled intent against the staged base *without* consulting the command's
/// receipt, and classifies the effect using the exact-base conflict rule
/// (R-SYNC-006, data-model.md §6 conflict policy #2).
///
/// Bypassing the receipt is the whole point: the ordinary command path
/// short-circuits a replay by returning the stored receipt, which would make a
/// rebase a no-op and silently drop the command's effect onto the new base.
/// The rebaser instead always runs the intent, so every pending command
/// produces exactly one effect — a new-epoch outbox group when the staged base
/// still matches the command's base, or a durable conflict when it diverged.
/// Either way the command's original stable result is echoed unchanged.
library;

import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';

/// Replays journaled intents deterministically. Group and conflict ids are
/// derived from the command id so a re-run of the same bootstrap is idempotent.
final class JournalReplayRebaser implements PendingCommandRebaser {
  const JournalReplayRebaser();

  @override
  Future<RebaseResult> rebase(
    StagedGeneration staged,
    PendingCommandRecord command, {
    required int newEpoch,
  }) async {
    final int? stagedVersion = await staged.stagedVersionOf(
      command.entityType,
      command.entityId,
    );
    final int? base = command.baseRowVersion;

    // Exact-base rule: the intent applies cleanly only when the staged base is
    // exactly what the command was authored against. An insert applies only
    // when no staged row exists; a patch/delete applies only when the staged
    // version equals the command's base version. Any divergence — including a
    // remote insert under an insert, or a remote tombstone under a patch — is
    // preserved as a durable conflict.
    final bool appliesCleanly = base == null
        ? stagedVersion == null
        : stagedVersion == base;

    if (appliesCleanly) {
      final int newRowVersion = (base ?? 0) + 1;
      await staged.recordNewEpochGroup(
        StagedGroupDraft(
          groupId: _groupId(command),
          epoch: newEpoch,
          entityType: command.entityType,
          entityId: command.entityId,
          newRowVersion: newRowVersion,
          canonicalPayload: command.canonicalPayload,
        ),
      );
      return RebaseResult(
        commandId: command.commandId,
        effect: RebaseEffect.newEpochGroup,
        stableResultCode: command.originalResultCode,
        stablePayloadVersion: command.originalPayloadVersion,
        newGroupId: _groupId(command),
      );
    }

    await staged.recordDurableConflict(
      StagedConflictDraft(
        artifactId: _conflictId(command),
        entityType: command.entityType,
        entityId: command.entityId,
        baseRowVersion: base,
        stagedRowVersion: stagedVersion ?? 0,
      ),
    );
    return RebaseResult(
      commandId: command.commandId,
      effect: RebaseEffect.durableConflict,
      stableResultCode: command.originalResultCode,
      stablePayloadVersion: command.originalPayloadVersion,
      conflictArtifactId: _conflictId(command),
    );
  }

  /// A rebased command reuses its original outbox group id when it had one, so
  /// a re-run does not fork a second group; otherwise it derives one from the
  /// command id.
  static String _groupId(PendingCommandRecord command) =>
      command.syncGroupId ?? 'rebase-group-${command.commandId}';

  static String _conflictId(PendingCommandRecord command) =>
      'rebase-conflict-${command.commandId}';
}
