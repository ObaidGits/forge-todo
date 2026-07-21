import 'package:forge/core/domain/id.dart';

/// A durable command envelope (design.md §5, R-GEN-005).
///
/// Every durable command carries a stable [commandId], the owning [profileId],
/// a canonical [requestHash] used for receipt deduplication, and the immutable
/// [canonicalPayload]/[baseVersions] recorded in the pending-command journal.
final class DurableCommand {
  const DurableCommand({
    required this.profileId,
    required this.commandId,
    required this.commandType,
    required this.schemaVersion,
    required this.requestHash,
    required this.canonicalPayload,
    this.baseVersions,
  });

  final ProfileId profileId;
  final CommandId commandId;

  /// Stable command-type discriminator recorded in the journal.
  final String commandType;

  /// Payload schema version for forward-compatible journal decoding.
  final int schemaVersion;

  /// Canonical hash of the request; a matching hash replays the stored result,
  /// a different hash under the same id is rejected (R-GEN-005).
  final String requestHash;

  /// Immutable canonical intent stored in `pending_command_journal`.
  final String canonicalPayload;

  /// Optional exact base versions captured for later conflict detection.
  final Map<String, int>? baseVersions;
}

/// An append to `activity_events` produced by a command body.
final class ActivityDraft {
  const ActivityDraft({
    required this.id,
    required this.eventType,
    required this.entityType,
    required this.entityId,
    required this.payloadVersion,
    this.payload,
  });

  final String id;
  final String eventType;
  final String entityType;
  final String entityId;
  final int payloadVersion;
  final String? payload;
}

/// A durable projection dirty marker produced by a command body.
final class DirtyProjectionDraft {
  const DirtyProjectionDraft({
    required this.projection,
    required this.projectionKey,
  });

  /// Projection name, e.g. `search` for the authoritative FTS projection
  /// (R-NOTE-004) or `today` for the Today view.
  final String projection;
  final String projectionKey;
}

/// A single ordered operation within one semantic outbox group.
///
/// The group as a whole is accepted or rejected by the server (R-SYNC-002); the
/// [index]/[count] pin the deterministic order.
final class OutboxOperationDraft {
  const OutboxOperationDraft({
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.opKind,
    required this.payload,
    this.changedFields,
    this.baseRowVersion,
    this.baseFieldVersions,
  });

  final String operationId;
  final String entityType;
  final String entityId;

  /// One of `insert`, `patch`, `delete`.
  final String opKind;
  final String payload;
  final String? changedFields;
  final int? baseRowVersion;
  final String? baseFieldVersions;
}

/// A sync-eligible semantic group: an ordered [operations] list committed under
/// a single [groupId] alongside its immutable journal entry (design.md §5).
final class OutboxGroupDraft {
  const OutboxGroupDraft({
    required this.groupId,
    required this.operations,
    required this.snapshotEpoch,
  });

  final String groupId;
  final List<OutboxOperationDraft> operations;
  final int snapshotEpoch;

  bool get isEmpty => operations.isEmpty;
}

/// A volatile after-commit acceleration hint (design.md §5).
///
/// Hints carry only IDs and minimal metadata; they are dispatched after commit
/// to idempotent handlers and never perform authoritative writes.
final class AfterCommitHint {
  const AfterCommitHint({
    required this.kind,
    required this.entityType,
    required this.entityId,
  });

  /// Hint discriminator, e.g. `projection` or `reminder`.
  final String kind;
  final String entityType;
  final String entityId;

  @override
  bool operator ==(Object other) =>
      other is AfterCommitHint &&
      other.kind == kind &&
      other.entityType == entityType &&
      other.entityId == entityId;

  @override
  int get hashCode => Object.hash(kind, entityType, entityId);
}

/// The complete effect of a command body, returned to the command bus so the
/// cross-cutting write set (commit log, receipt, journal, activity, dirty,
/// outbox) commits atomically with the domain rows the body already wrote.
final class SemanticWrite {
  const SemanticWrite({
    required this.resultCode,
    required this.payloadVersion,
    this.resultPayload,
    this.activity = const <ActivityDraft>[],
    this.dirtyProjections = const <DirtyProjectionDraft>[],
    this.outboxGroup,
    this.afterCommitHints = const <AfterCommitHint>[],
  });

  /// Stable committed result code stored in the receipt and replayed verbatim.
  final String resultCode;
  final int payloadVersion;
  final String? resultPayload;
  final List<ActivityDraft> activity;
  final List<DirtyProjectionDraft> dirtyProjections;

  /// The sync-eligible group, or null for a local-only command. When present
  /// and non-empty, an immutable journal entry is created atomically.
  final OutboxGroupDraft? outboxGroup;

  /// Volatile IDs-only hints dispatched after the transaction commits.
  final List<AfterCommitHint> afterCommitHints;
}

/// The stable committed result of a durable command (R-GEN-005). UI, widget,
/// and notification callers receive this, never a dispatch acknowledgement.
final class CommittedCommandResult {
  const CommittedCommandResult({
    required this.commandId,
    required this.resultCode,
    required this.payloadVersion,
    required this.commitSeq,
    required this.replayed,
    this.resultPayload,
  });

  final CommandId commandId;
  final String resultCode;
  final int payloadVersion;
  final String? resultPayload;

  /// The commit sequence at which the command's effect became durable. For a
  /// replayed receipt this is the original commit sequence.
  final int commitSeq;

  /// True when this result came from an existing receipt rather than a fresh
  /// commit (idempotent replay).
  final bool replayed;
}
