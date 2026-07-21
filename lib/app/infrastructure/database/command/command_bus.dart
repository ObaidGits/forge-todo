import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/command/search_projection_coordinator.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/result.dart';

/// Produces the semantic effect of a durable command, writing its domain and
/// authoritative search rows through the session repositories and returning the
/// cross-cutting write set for atomic persistence.
typedef CommandBody =
    Future<SemanticWrite> Function(TransactionSession session);

/// Thrown internally when the same command id is replayed with a different
/// request hash (R-GEN-005). Rolls back the transaction and maps to a conflict.
final class _ReceiptHashMismatch implements Exception {
  const _ReceiptHashMismatch();
}

/// Thrown internally when a non-local origin attempts to enqueue outbox work.
final class _IllegalOutboxOrigin implements Exception {
  const _IllegalOutboxOrigin(this.origin);
  final WriteOrigin origin;
}

/// The outer command bus (design.md §5, R-GEN-005).
///
/// It first checks `command_receipts(profile_id, command_id)`: a matching hash
/// returns the stored result; a different hash is rejected. Otherwise one
/// transaction writes domain rows (via [CommandBody]), authoritative search
/// rows, activity, dirty projections, any sync-eligible outbox group and its
/// immutable pending-command journal entry, the receipt, and the local commit
/// sequence — then commits and publishes volatile after-commit hints.
final class ForgeCommandBus {
  ForgeCommandBus({
    required this.unitOfWork,
    required this.clock,
    this.afterCommit,
    this.searchCoordinator,
  });

  final UnitOfWork unitOfWork;
  final Clock clock;
  final AfterCommitDispatcher? afterCommit;

  /// Optional in-transaction search projection coordinator. When wired, the bus
  /// maintains `search_documents`/`search_fts` atomically with the domain write
  /// for every `search` dirty marker and clears the marker it handled. When
  /// null, `search` markers are left for startup/resume reconciliation.
  final SearchProjectionCoordinator? searchCoordinator;

  Future<Result<CommittedCommandResult>> execute(
    DurableCommand command,
    CommandBody body, {
    WriteOrigin origin = WriteOrigin.localCommand,
  }) async {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    List<AfterCommitHint> hints = const <AfterCommitHint>[];
    try {
      final CommittedCommandResult result = await unitOfWork
          .transaction<CommittedCommandResult>(origin: origin, (
            TransactionSession session,
          ) async {
            final CommandReceiptRepository receipts = session.repositories
                .resolve<CommandReceiptRepository>();
            final StoredReceipt? existing = await receipts.find(
              command.profileId.value,
              command.commandId.value,
            );
            if (existing != null) {
              if (existing.requestHash != command.requestHash) {
                throw const _ReceiptHashMismatch();
              }
              // Idempotent replay: return the stored, stable result verbatim.
              return CommittedCommandResult(
                commandId: command.commandId,
                resultCode: existing.resultCode,
                resultPayload: existing.resultPayload,
                payloadVersion: existing.payloadVersion,
                commitSeq: existing.commitSeq,
                replayed: true,
              );
            }

            final SemanticWrite write = await body(session);
            hints = write.afterCommitHints;
            await _persist(session, command, write, origin, now);
            return CommittedCommandResult(
              commandId: command.commandId,
              resultCode: write.resultCode,
              resultPayload: write.resultPayload,
              payloadVersion: write.payloadVersion,
              commitSeq: session.commitSeq,
              replayed: false,
            );
          });

      if (!result.replayed && hints.isNotEmpty) {
        await afterCommit?.dispatch(hints);
      }
      return Success<CommittedCommandResult>(result);
    } on _ReceiptHashMismatch {
      return const Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.conflict,
          code: 'command.receipt_hash_mismatch',
          safeMessageKey: 'error.command.duplicate_conflict',
          retryable: false,
        ),
      );
    } on _IllegalOutboxOrigin catch (error) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.unexpected,
          code: 'command.illegal_outbox_origin',
          safeMessageKey: 'error.command.unexpected',
          retryable: false,
          redactedCause: error.origin.name,
        ),
      );
    }
  }

  Future<void> _persist(
    TransactionSession session,
    DurableCommand command,
    SemanticWrite write,
    WriteOrigin origin,
    int now,
  ) async {
    final String profileId = command.profileId.value;
    final int commitSeq = session.commitSeq;

    final OutboxGroupDraft? group = write.outboxGroup;
    final bool hasOutbox = group != null && !group.isEmpty;
    if (hasOutbox &&
        origin != WriteOrigin.localCommand &&
        origin != WriteOrigin.bootstrapRebase) {
      // data-model §1: only local_command and bootstrap_rebase enqueue outbox.
      throw _IllegalOutboxOrigin(origin);
    }

    // Commit sequence and commit log.
    await session.repositories.resolve<CommitLogRepository>().append(
      profileId: profileId,
      commitSeq: commitSeq,
      commandId: command.commandId.value,
      writeOrigin: _originWireName(origin),
      committedAtUtc: now,
    );

    // Durable receipt with the stable committed result.
    await session.repositories.resolve<CommandReceiptRepository>().insert(
      profileId: profileId,
      commandId: command.commandId.value,
      requestHash: command.requestHash,
      resultCode: write.resultCode,
      resultPayload: write.resultPayload,
      payloadVersion: write.payloadVersion,
      commitSeq: commitSeq,
      createdAtUtc: now,
    );

    // Activity feed.
    final ActivityRepository activity = session.repositories
        .resolve<ActivityRepository>();
    for (final ActivityDraft draft in write.activity) {
      await activity.append(
        id: draft.id,
        profileId: profileId,
        eventType: draft.eventType,
        entityType: draft.entityType,
        entityId: draft.entityId,
        occurredAtUtc: now,
        payloadVersion: draft.payloadVersion,
        commandId: command.commandId.value,
        commitSeq: commitSeq,
        payload: draft.payload,
      );
    }

    // Durable projection dirty markers (search, Today, etc.).
    final ProjectionDirtyRepository dirty = session.repositories
        .resolve<ProjectionDirtyRepository>();
    for (final DirtyProjectionDraft draft in write.dirtyProjections) {
      await dirty.mark(
        profileId: profileId,
        projection: draft.projection,
        projectionKey: draft.projectionKey,
        sourceCommitSeq: commitSeq,
        updatedAtUtc: now,
      );
    }

    // Maintain the unified search index in the SAME transaction (design.md §14,
    // data-model §4). The coordinator upserts/tombstones documents and their
    // FTS rows atomically with the domain write; the handled search markers are
    // then cleared because their watermark has reached this commit sequence.
    final SearchProjectionCoordinator? coordinator = searchCoordinator;
    if (coordinator != null) {
      final List<DirtyProjectionDraft> searchMarkers = write.dirtyProjections
          .where((DirtyProjectionDraft d) => d.projection == 'search')
          .toList(growable: false);
      if (searchMarkers.isNotEmpty) {
        await coordinator.maintain(session, profileId, searchMarkers, now);
        for (final DirtyProjectionDraft draft in searchMarkers) {
          await dirty.clear(
            profileId: profileId,
            projection: draft.projection,
            projectionKey: draft.projectionKey,
            reconciledCommitSeq: commitSeq,
          );
        }
      }
    }

    // Sync-eligible outbox group + immutable journal entry.
    if (hasOutbox) {
      await session.repositories.resolve<OutboxRepository>().enqueueGroup(
        profileId: profileId,
        groupId: group.groupId,
        snapshotEpoch: group.snapshotEpoch,
        nowUtc: now,
        operations: group.operations
            .map(
              (OutboxOperationDraft op) => OutboxInsert(
                operationId: op.operationId,
                entityType: op.entityType,
                entityId: op.entityId,
                opKind: op.opKind,
                payload: op.payload,
                changedFields: op.changedFields,
                baseRowVersion: op.baseRowVersion,
                baseFieldVersions: op.baseFieldVersions,
              ),
            )
            .toList(growable: false),
      );

      await session.repositories
          .resolve<PendingCommandJournalRepository>()
          .insert(
            profileId: profileId,
            commandId: command.commandId.value,
            commandType: command.commandType,
            schemaVersion: command.schemaVersion,
            canonicalPayload: command.canonicalPayload,
            originalResultCode: write.resultCode,
            originalPayloadVersion: write.payloadVersion,
            baseVersions: _encodeBaseVersions(command.baseVersions),
            commitSeq: commitSeq,
            syncGroupId: group.groupId,
            createdAtUtc: now,
          );
    }
  }

  static String _originWireName(WriteOrigin origin) => switch (origin) {
    WriteOrigin.localCommand => 'local_command',
    WriteOrigin.remoteApply => 'remote_apply',
    WriteOrigin.bootstrapRebase => 'bootstrap_rebase',
    WriteOrigin.restore => 'restore',
    WriteOrigin.migration => 'migration',
  };

  static String? _encodeBaseVersions(Map<String, int>? baseVersions) {
    if (baseVersions == null || baseVersions.isEmpty) {
      return null;
    }
    final List<String> entries = baseVersions.entries
        .map((MapEntry<String, int> e) => '${_jsonString(e.key)}:${e.value}')
        .toList(growable: false);
    return '{${entries.join(',')}}';
  }

  static String _jsonString(String value) {
    final String escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }
}
