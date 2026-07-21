/// The point-in-time inventory a bootstrap/rebase captures from the active
/// local generation before it builds an unexposed replacement (R-SYNC-006,
/// data-model.md §6 "Bootstrap, relink, and auth").
///
/// The inventory is taken at exactly one `commit_seq` after command admission
/// has been closed and active transactions and sync workers have settled, so no
/// post-inventory command-capture path exists. It records every piece of state
/// that must be preserved across the generation switch:
///
///  * local-only rows/files (drafts, attachment metadata/files, private
///    settings, caches, generation metadata) that never enter protocol
///    payloads (R-SYNC-002);
///  * every durable command receipt (so an idempotent replay still returns its
///    original stable result);
///  * every pending command's canonical journal payload/base/original result,
///    in commit order, so the journal can be rebased onto the new base without
///    a receipt short-circuiting replay.
///
/// Nothing here imports Drift/Flutter/Supabase: the inventory is a pure value
/// object so the bootstrap orchestration can be reasoned about and tested with
/// deterministic fakes.
library;

/// The category of a preserved local-only item. Every category is copied into
/// the staged generation verbatim during a bootstrap; none may be discarded
/// (R-SYNC-006 "no draft, setting, attachment, receipt, conflict or pending
/// intent may be discarded").
enum LocalOnlyKind {
  /// An unsaved or in-progress draft.
  draft,

  /// Attachment metadata and the local file journal entry for a blob.
  attachmentMetadata,

  /// A private, never-replicated setting.
  privateSetting,

  /// A recomputable cache or derived projection snapshot.
  cache,

  /// Generation/runtime metadata local to this device.
  generationMetadata,
}

/// One preserved local-only item with a content hash used to verify the copy
/// into the staged generation is byte-for-byte faithful.
final class LocalOnlyItem {
  LocalOnlyItem({
    required this.kind,
    required this.id,
    required this.contentHash,
    Map<String, Object?> payload = const <String, Object?>{},
  }) : payload = Map<String, Object?>.unmodifiable(payload) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
    if (contentHash.isEmpty) {
      throw ArgumentError.value(
        contentHash,
        'contentHash',
        'Must not be empty.',
      );
    }
  }

  final LocalOnlyKind kind;
  final String id;

  /// A stable hash over the item's canonical bytes; the copy is verified by
  /// comparing this against the staged item's recomputed hash.
  final String contentHash;

  /// The item's opaque payload; carried so the copy is faithful.
  final Map<String, Object?> payload;
}

/// A durable command receipt (data-model.md §3 `command_receipts`).
///
/// A receipt binds a `command_id` to its request hash and the exact stable
/// result the command produced. A bootstrap preserves every receipt so replays
/// stay idempotent; a pending command's receipt is imported unchanged only
/// after its intent is rebased (see [PendingCommandRecord]).
final class ReceiptRecord {
  ReceiptRecord({
    required this.commandId,
    required this.requestHash,
    required this.resultCode,
    required this.payloadVersion,
    required this.commitSeq,
    this.resultPayload,
  }) {
    if (commandId.isEmpty) {
      throw ArgumentError.value(commandId, 'commandId', 'Must not be empty.');
    }
  }

  final String commandId;
  final String requestHash;
  final String resultCode;
  final String? resultPayload;
  final int payloadVersion;
  final int commitSeq;
}

/// One pending command's canonical journal record captured for rebase
/// (data-model.md §3 `pending_command_journal`).
///
/// The record carries the immutable intent (canonical payload) the command
/// committed, the base row version it was authored against (null for an
/// insert), and the original stable result. During rebase the journaled intent
/// is replayed against the staged base *without* consulting the receipt, so the
/// replay actually runs; the original result is then restored unchanged.
final class PendingCommandRecord {
  PendingCommandRecord({
    required this.commandId,
    required this.commitSeq,
    required this.commandType,
    required this.entityType,
    required this.entityId,
    required this.canonicalPayload,
    required this.originalResultCode,
    required this.originalPayloadVersion,
    this.baseRowVersion,
    this.syncGroupId,
  }) {
    if (commandId.isEmpty) {
      throw ArgumentError.value(commandId, 'commandId', 'Must not be empty.');
    }
    if (baseRowVersion != null && baseRowVersion! < 0) {
      throw ArgumentError.value(
        baseRowVersion,
        'baseRowVersion',
        'Must be nonnegative.',
      );
    }
  }

  final String commandId;
  final int commitSeq;
  final String commandType;
  final String entityType;
  final String entityId;

  /// The immutable, canonical journaled intent replayed during rebase.
  final String canonicalPayload;

  final String originalResultCode;
  final int originalPayloadVersion;

  /// The base row version the command was authored against, or null when the
  /// command inserted a new entity (an insert can never collide on base).
  final int? baseRowVersion;

  /// The original outbox group id, when the command enqueued sync work.
  final String? syncGroupId;
}

/// A complete, point-in-time inventory captured at one [commitSeq].
final class LocalInventory {
  LocalInventory({
    required this.commitSeq,
    Iterable<LocalOnlyItem> localOnly = const <LocalOnlyItem>[],
    Iterable<ReceiptRecord> receipts = const <ReceiptRecord>[],
    Iterable<PendingCommandRecord> pendingCommands =
        const <PendingCommandRecord>[],
  }) : localOnly = List<LocalOnlyItem>.unmodifiable(localOnly),
       receipts = List<ReceiptRecord>.unmodifiable(receipts),
       pendingCommands = List<PendingCommandRecord>.unmodifiable(
         _sortedByCommitSeq(pendingCommands),
       ) {
    if (commitSeq < 0) {
      throw ArgumentError.value(commitSeq, 'commitSeq', 'Must be nonnegative.');
    }
  }

  /// The single commit sequence the whole inventory was snapshotted at.
  final int commitSeq;

  final List<LocalOnlyItem> localOnly;

  /// Every durable receipt captured (both pending-command receipts and the
  /// rest).
  final List<ReceiptRecord> receipts;

  /// Pending commands in ascending commit order — the exact order rebase must
  /// replay them in.
  final List<PendingCommandRecord> pendingCommands;

  /// The set of command ids that still have pending (un-acknowledged) intents.
  Set<String> get pendingCommandIds =>
      pendingCommands.map((PendingCommandRecord c) => c.commandId).toSet();

  /// Receipts that belong to a pending command; these are imported unchanged
  /// only after the command's intent is rebased.
  List<ReceiptRecord> get pendingCommandReceipts {
    final Set<String> ids = pendingCommandIds;
    return receipts
        .where((ReceiptRecord r) => ids.contains(r.commandId))
        .toList(growable: false);
  }

  /// Receipts that do not belong to a pending command; these are copied
  /// normally alongside the other local-only state.
  List<ReceiptRecord> get settledReceipts {
    final Set<String> ids = pendingCommandIds;
    return receipts
        .where((ReceiptRecord r) => !ids.contains(r.commandId))
        .toList(growable: false);
  }

  static List<PendingCommandRecord> _sortedByCommitSeq(
    Iterable<PendingCommandRecord> commands,
  ) {
    final List<PendingCommandRecord> sorted = commands.toList();
    sorted.sort(
      (PendingCommandRecord a, PendingCommandRecord b) =>
          a.commitSeq.compareTo(b.commitSeq),
    );
    return sorted;
  }
}
