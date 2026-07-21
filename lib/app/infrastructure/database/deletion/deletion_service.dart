import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_maintenance.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';

/// Thrown inside a command body when the target row does not exist.
final class _EntityMissing implements Exception {
  const _EntityMissing(this.ref);
  final EntityRef ref;
}

/// Thrown inside a hard-purge body when the confirmation no longer matches the
/// currently purgeable set (the set changed since preview).
final class _ConfirmationMismatch implements Exception {
  const _ConfirmationMismatch();
}

/// Thrown inside a hard-purge body when an intended target is now blocked.
final class _PurgeBlocked implements Exception {
  const _PurgeBlocked(this.reasons);
  final List<String> reasons;
}

/// Soft-delete, reversible Undo/restore, and blocked-and-confirmed hard purge,
/// all expressed as durable commands over [ForgeCommandBus] (R-GEN-003).
///
/// * Deletion soft-deletes by default and returns immediately with an Undo
///   handle; nothing is destroyed (NFR-UX-002 prefers Undo to confirmation).
/// * Restore clears the tombstone, preserving the row id and every link/child
///   that referenced it.
/// * Hard purge is a persisted idempotent command that only runs after an
///   affected-count preview and an explicit confirmation, and is refused while
///   any target still has pending outbox operations, open conflicts, unexpired
///   remote retention, or in-flight file-journal state. There is no override.
final class DeletionService {
  DeletionService({
    required this.bus,
    required this.registry,
    required this.clock,
    required this.idGenerator,
    this.snapshotEpoch = 0,
    this.maintenanceHooks = const <String, DeletionMaintenanceHook>{},
  });

  final ForgeCommandBus bus;
  final TrashRegistry registry;
  final Clock clock;
  final IdGenerator idGenerator;

  /// Per-entity-type maintenance hooks invoked inside the deletion transaction
  /// after each tombstone change so feature-derived state (e.g. inbound
  /// wiki-link resolution, R-NOTE-003) is repaired in the same commit.
  final Map<String, DeletionMaintenanceHook> maintenanceHooks;

  /// Snapshot epoch stamped on tombstone outbox operations before a sync link
  /// exists. Sync waves supply the live epoch.
  final int snapshotEpoch;

  /// Soft-deletes [ref], exposing Undo immediately. Idempotent for an
  /// already-deleted row; rejects a missing row as a validation failure.
  Future<Result<CommittedCommandResult>> softDelete({
    required DurableCommand command,
    required EntityRef ref,
  }) => _mutate(
    command,
    (TransactionSession session) =>
        _softDeleteBody(session, command.profileId, <EntityRef>[ref]),
  );

  /// Soft-deletes every live row in [refs] as one atomic semantic group. The
  /// caller SHALL first preview affected counts (R-GEN-003).
  Future<Result<CommittedCommandResult>> softDeleteBulk({
    required DurableCommand command,
    required List<EntityRef> refs,
  }) => _mutate(
    command,
    (TransactionSession session) =>
        _softDeleteBody(session, command.profileId, refs),
  );

  /// Restores (undoes the deletion of) [ref], preserving its id and links.
  Future<Result<CommittedCommandResult>> restore({
    required DurableCommand command,
    required EntityRef ref,
  }) => _mutate(
    command,
    (TransactionSession session) =>
        _restoreBody(session, command.profileId, <EntityRef>[ref]),
  );

  /// Restores every soft-deleted row in [refs] as one atomic group.
  Future<Result<CommittedCommandResult>> restoreBulk({
    required DurableCommand command,
    required List<EntityRef> refs,
  }) => _mutate(
    command,
    (TransactionSession session) =>
        _restoreBody(session, command.profileId, refs),
  );

  /// Permanently removes the purgeable rows among [refs]. Requires a
  /// [confirmation] that matches the currently purgeable set and re-checks
  /// blocks inside the transaction; the command receipt makes replay
  /// idempotent (R-GEN-003, R-GEN-005).
  Future<Result<CommittedCommandResult>> hardPurge({
    required DurableCommand command,
    required List<EntityRef> refs,
    required PurgeConfirmation confirmation,
  }) async {
    try {
      return await bus.execute(
        command,
        (TransactionSession session) =>
            _hardPurgeBody(session, command.profileId, refs, confirmation),
      );
    } on _ConfirmationMismatch {
      return const Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'purge.confirmation_mismatch',
          safeMessageKey: 'error.purge.reconfirm',
          retryable: false,
        ),
      );
    } on _PurgeBlocked catch (blocked) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.conflict,
          code: 'purge.blocked',
          safeMessageKey: 'error.purge.blocked',
          retryable: true,
          redactedCause: blocked.reasons.join(','),
        ),
      );
    }
  }

  Future<Result<CommittedCommandResult>> _mutate(
    DurableCommand command,
    CommandBody body,
  ) async {
    try {
      return await bus.execute(command, body);
    } on _EntityMissing catch (missing) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'deletion.entity_missing',
          safeMessageKey: 'error.deletion.missing',
          retryable: false,
          redactedCause: missing.ref.entityType,
        ),
      );
    }
  }

  Future<SemanticWrite> _softDeleteBody(
    TransactionSession session,
    ProfileId profile,
    List<EntityRef> refs,
  ) async {
    final TrashRepository trash = session.repositories
        .resolve<TrashRepository>();
    final int now = clock.utcNow().microsecondsSinceEpoch;
    final List<ActivityDraft> activity = <ActivityDraft>[];
    final List<DirtyProjectionDraft> dirty = <DirtyProjectionDraft>[];
    final List<OutboxOperationDraft> operations = <OutboxOperationDraft>[];
    for (final EntityRef ref in refs) {
      final TrashableEntity descriptor = registry.require(ref.entityType);
      final TrashState state = await trash.stateOf(
        descriptor,
        profile.value,
        ref.entityId,
      );
      if (!state.exists) {
        throw _EntityMissing(ref);
      }
      if (state.isDeleted) {
        continue; // Idempotent: already in the trash.
      }
      await trash.softDelete(descriptor, profile.value, ref.entityId, now);
      await _runMaintenance(
        session,
        profile,
        ref,
        DeletionAction.softDelete,
        now,
      );
      activity.add(_activity('soft_deleted', ref));
      dirty.add(_searchDirty(ref));
      if (descriptor.syncEligible) {
        operations.add(
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: ref.entityType,
            entityId: ref.entityId,
            opKind: 'delete',
            payload: '{"deleted_at_utc":$now}',
          ),
        );
      }
    }
    return SemanticWrite(
      resultCode: activity.isEmpty ? 'noop' : 'soft_deleted',
      payloadVersion: 1,
      resultPayload: '{"affected":${activity.length}}',
      activity: activity,
      dirtyProjections: dirty,
      outboxGroup: _groupOrNull(operations),
    );
  }

  Future<SemanticWrite> _restoreBody(
    TransactionSession session,
    ProfileId profile,
    List<EntityRef> refs,
  ) async {
    final TrashRepository trash = session.repositories
        .resolve<TrashRepository>();
    final List<ActivityDraft> activity = <ActivityDraft>[];
    final List<DirtyProjectionDraft> dirty = <DirtyProjectionDraft>[];
    final List<OutboxOperationDraft> operations = <OutboxOperationDraft>[];
    for (final EntityRef ref in refs) {
      final TrashableEntity descriptor = registry.require(ref.entityType);
      final TrashState state = await trash.stateOf(
        descriptor,
        profile.value,
        ref.entityId,
      );
      if (!state.exists) {
        throw _EntityMissing(ref);
      }
      if (!state.isDeleted) {
        continue; // Idempotent: already live.
      }
      await trash.restore(descriptor, profile.value, ref.entityId);
      final int restoredNow = clock.utcNow().microsecondsSinceEpoch;
      await _runMaintenance(
        session,
        profile,
        ref,
        DeletionAction.restore,
        restoredNow,
      );
      activity.add(_activity('restored', ref));
      dirty.add(_searchDirty(ref));
      if (descriptor.syncEligible) {
        operations.add(
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: ref.entityType,
            entityId: ref.entityId,
            opKind: 'patch',
            changedFields: 'deleted_at_utc',
            payload: '{"deleted_at_utc":null}',
          ),
        );
      }
    }
    return SemanticWrite(
      resultCode: activity.isEmpty ? 'noop' : 'restored',
      payloadVersion: 1,
      resultPayload: '{"affected":${activity.length}}',
      activity: activity,
      dirtyProjections: dirty,
      outboxGroup: _groupOrNull(operations),
    );
  }

  Future<SemanticWrite> _hardPurgeBody(
    TransactionSession session,
    ProfileId profile,
    List<EntityRef> refs,
    PurgeConfirmation confirmation,
  ) async {
    final TrashRepository trash = session.repositories
        .resolve<TrashRepository>();
    final PurgeGuardRepository guard = session.repositories
        .resolve<PurgeGuardRepository>();
    final int now = clock.utcNow().microsecondsSinceEpoch;

    final List<EntityRef> purgeable = <EntityRef>[];
    final List<String> blockedReasons = <String>[];
    for (final EntityRef ref in refs) {
      final TrashableEntity descriptor = registry.require(ref.entityType);
      final TrashState state = await trash.stateOf(
        descriptor,
        profile.value,
        ref.entityId,
      );
      if (!state.exists || !state.isDeleted) {
        continue;
      }
      final PurgeBlocks blocks = await _blocks(guard, profile, ref, now);
      if (blocks.isBlocked) {
        blockedReasons.addAll(blocks.reasons);
        continue;
      }
      purgeable.add(ref);
    }

    // Hard purge is all-or-nothing over the requested in-trash targets: if any
    // is still blocked, refuse the whole operation (R-GEN-003, no override).
    if (blockedReasons.isNotEmpty) {
      throw _PurgeBlocked(blockedReasons);
    }

    final PurgeConfirmation expected = PurgeConfirmation.forRefs(
      purgeable,
      purgeable.length,
    );
    if (expected != confirmation) {
      throw const _ConfirmationMismatch();
    }

    final List<ActivityDraft> activity = <ActivityDraft>[];
    final List<DirtyProjectionDraft> dirty = <DirtyProjectionDraft>[];
    for (final EntityRef ref in purgeable) {
      final TrashableEntity descriptor = registry.require(ref.entityType);
      await trash.hardDelete(descriptor, profile.value, ref.entityId);
      await _runMaintenance(
        session,
        profile,
        ref,
        DeletionAction.hardPurge,
        now,
      );
      activity.add(_activity('purged', ref));
      dirty.add(_searchDirty(ref));
    }

    // Hard purge is a local storage reclamation performed only after the
    // tombstone already replicated and its retention elapsed, so it never
    // enqueues outbox work.
    return SemanticWrite(
      resultCode: 'purged',
      payloadVersion: 1,
      resultPayload: '{"purged":${purgeable.length}}',
      activity: activity,
      dirtyProjections: dirty,
    );
  }

  Future<PurgeBlocks> _blocks(
    PurgeGuardRepository guard,
    ProfileId profile,
    EntityRef ref,
    int nowUtc,
  ) async {
    final int pendingOutbox = await guard.pendingOutboxCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    final int openConflicts = await guard.openConflictCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    final int retention = await guard.retentionCount(
      profile.value,
      ref.entityType,
      ref.entityId,
      nowUtc,
    );
    final int fileOps = await guard.pendingFileOpsCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    return PurgeBlocks(
      pendingOutbox: pendingOutbox,
      openConflicts: openConflicts,
      remoteRetention: retention,
      pendingFileOps: fileOps,
    );
  }

  /// Runs the registered maintenance hook (if any) for [ref]'s entity type,
  /// inside the current transaction, so feature-derived state is repaired
  /// atomically with the tombstone change.
  Future<void> _runMaintenance(
    TransactionSession session,
    ProfileId profile,
    EntityRef ref,
    DeletionAction action,
    int nowUtc,
  ) async {
    final DeletionMaintenanceHook? hook = maintenanceHooks[ref.entityType];
    if (hook == null) {
      return;
    }
    await hook.apply(session, profile, ref.entityId, action, nowUtc);
  }

  ActivityDraft _activity(String eventType, EntityRef ref) => ActivityDraft(
    id: idGenerator.uuidV7(),
    eventType: eventType,
    entityType: ref.entityType,
    entityId: ref.entityId,
    payloadVersion: 1,
  );

  /// The unified-search dirty marker for [ref]. The key encodes the entity type
  /// as `"<entityType>:<entityId>"` so the transactional search projector
  /// registry (and startup reconciler) can route it to the projector that owns
  /// the type; a bare id cannot be routed and would strand the marker. This
  /// matches the search feature's `SearchDirtyKey` convention (design.md §14).
  DirtyProjectionDraft _searchDirty(EntityRef ref) => DirtyProjectionDraft(
    projection: 'search',
    projectionKey: '${ref.entityType}:${ref.entityId}',
  );

  OutboxGroupDraft? _groupOrNull(List<OutboxOperationDraft> operations) {
    if (operations.isEmpty) {
      return null;
    }
    return OutboxGroupDraft(
      groupId: idGenerator.uuidV7(),
      snapshotEpoch: snapshotEpoch,
      operations: operations,
    );
  }
}
