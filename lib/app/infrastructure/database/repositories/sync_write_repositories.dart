import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// Journal / outbox state values shared across the sync write set.
///
/// Mirrors the CHECK constraints on `pending_command_journal.state` and
/// `outbox_mutations.state` (data-model §3).
abstract final class SyncWriteState {
  static const String pending = 'pending';
  static const String inFlight = 'in_flight';
  static const String acknowledged = 'acknowledged';
  static const String terminalConflict = 'terminal_conflict';
}

/// Base for a transaction-scoped sync-write repository.
abstract base class SyncWriteRepository {
  SyncWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;
}

/// A pending-command journal row (data-model §3).
final class JournalEntry {
  const JournalEntry({
    required this.commandId,
    required this.state,
    required this.commitSeq,
    this.syncGroupId,
    this.retainedUntilUtc,
    this.acknowledgedAtUtc,
  });

  final String commandId;
  final String state;
  final int commitSeq;
  final String? syncGroupId;
  final int? retainedUntilUtc;
  final int? acknowledgedAtUtc;
}

/// Writes the immutable pending-command journal and advances its lifecycle.
final class PendingCommandJournalRepository extends SyncWriteRepository {
  PendingCommandJournalRepository(super.db, super.scope);

  /// Inserts the immutable journal entry created atomically with the semantic
  /// write (design.md §5). The canonical payload, base versions, and original
  /// result are never rewritten afterwards.
  Future<void> insert({
    required String profileId,
    required String commandId,
    required String commandType,
    required int schemaVersion,
    required String canonicalPayload,
    required String originalResultCode,
    required int originalPayloadVersion,
    required int commitSeq,
    required int createdAtUtc,
    String? baseVersions,
    String? syncGroupId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.pendingCommandJournal)
        .insert(
          PendingCommandJournalCompanion.insert(
            profileId: profileId,
            commandId: commandId,
            commandType: commandType,
            schemaVersion: schemaVersion,
            canonicalPayload: canonicalPayload,
            originalResultCode: originalResultCode,
            originalPayloadVersion: originalPayloadVersion,
            baseVersions: Value<String?>(baseVersions),
            commitSeq: commitSeq,
            syncGroupId: Value<String?>(syncGroupId),
            state: SyncWriteState.pending,
            createdAtUtc: createdAtUtc,
          ),
        );
  }

  Future<JournalEntry?> findByCommand(
    String profileId,
    String commandId,
  ) async {
    scope.ensureActive();
    final PendingCommandRow? row =
        await (db.select(db.pendingCommandJournal)..where(
              (PendingCommandJournal t) =>
                  t.profileId.equals(profileId) & t.commandId.equals(commandId),
            ))
            .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  Future<JournalEntry?> findByGroup(
    String profileId,
    String syncGroupId,
  ) async {
    scope.ensureActive();
    final PendingCommandRow? row =
        await (db.select(db.pendingCommandJournal)..where(
              (PendingCommandJournal t) =>
                  t.profileId.equals(profileId) &
                  t.syncGroupId.equals(syncGroupId),
            ))
            .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Advances the journal entry for [syncGroupId] to `in_flight` when sending
  /// begins. Retry-safe: only `pending` rows move.
  Future<void> markInFlight(String profileId, String syncGroupId) async {
    scope.ensureActive();
    await (db.update(db.pendingCommandJournal)..where(
          (PendingCommandJournal t) =>
              t.profileId.equals(profileId) &
              t.syncGroupId.equals(syncGroupId) &
              t.state.equals(SyncWriteState.pending),
        ))
        .write(
          const PendingCommandJournalCompanion(
            state: Value<String>(SyncWriteState.inFlight),
          ),
        );
  }

  /// Advances the journal entry for an accepted group to `acknowledged`.
  Future<void> markAcknowledged({
    required String profileId,
    required String syncGroupId,
    required int acknowledgedAtUtc,
    required int retainedUntilUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.pendingCommandJournal)..where(
          (PendingCommandJournal t) =>
              t.profileId.equals(profileId) & t.syncGroupId.equals(syncGroupId),
        ))
        .write(
          PendingCommandJournalCompanion(
            state: const Value<String>(SyncWriteState.acknowledged),
            acknowledgedAtUtc: Value<int>(acknowledgedAtUtc),
            retainedUntilUtc: Value<int>(retainedUntilUtc),
          ),
        );
  }

  /// Marks a preserved collision as terminal conflict.
  Future<void> markTerminalConflict({
    required String profileId,
    required String syncGroupId,
    required int retainedUntilUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.pendingCommandJournal)..where(
          (PendingCommandJournal t) =>
              t.profileId.equals(profileId) & t.syncGroupId.equals(syncGroupId),
        ))
        .write(
          PendingCommandJournalCompanion(
            state: const Value<String>(SyncWriteState.terminalConflict),
            retainedUntilUtc: Value<int>(retainedUntilUtc),
          ),
        );
  }

  /// Restart recovery: returns interrupted `in_flight` entries to `pending`
  /// so their idempotent group is retried (data-model §3).
  Future<int> resetInterrupted(String profileId) async {
    scope.ensureActive();
    return (db.update(db.pendingCommandJournal)..where(
          (PendingCommandJournal t) =>
              t.profileId.equals(profileId) &
              t.state.equals(SyncWriteState.inFlight),
        ))
        .write(
          const PendingCommandJournalCompanion(
            state: Value<String>(SyncWriteState.pending),
          ),
        );
  }

  /// Returns journal entries eligible for pruning consideration in [state]
  /// whose retention has elapsed at [nowUtc] (data-model §3).
  Future<List<JournalEntry>> retentionElapsed({
    required String profileId,
    required String state,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    final List<PendingCommandRow> rows =
        await (db.select(db.pendingCommandJournal)..where(
              (PendingCommandJournal t) =>
                  t.profileId.equals(profileId) &
                  t.state.equals(state) &
                  t.retainedUntilUtc.isNotNull() &
                  t.retainedUntilUtc.isSmallerOrEqualValue(nowUtc),
            ))
            .get();
    return rows.map(_map).toList(growable: false);
  }

  Future<void> delete(String profileId, String commandId) async {
    scope.ensureActive();
    await (db.delete(db.pendingCommandJournal)..where(
          (PendingCommandJournal t) =>
              t.profileId.equals(profileId) & t.commandId.equals(commandId),
        ))
        .go();
  }

  JournalEntry _map(PendingCommandRow row) => JournalEntry(
    commandId: row.commandId,
    state: row.state,
    commitSeq: row.commitSeq,
    syncGroupId: row.syncGroupId,
    retainedUntilUtc: row.retainedUntilUtc,
    acknowledgedAtUtc: row.acknowledgedAtUtc,
  );
}

/// A ready-to-send outbox operation.
final class OutboxOperation {
  const OutboxOperation({
    required this.operationId,
    required this.groupId,
    required this.entityType,
    required this.entityId,
    required this.opKind,
    required this.state,
  });

  final String operationId;
  final String groupId;
  final String entityType;
  final String entityId;
  final String opKind;
  final String state;
}

/// Writes and advances the transactional outbox.
final class OutboxRepository extends SyncWriteRepository {
  OutboxRepository(super.db, super.scope);

  /// Enqueues one ordered semantic group atomically. Every operation shares
  /// [groupId], carries its 0-based [OutboxOperationCompanion] index, and starts
  /// `pending` (R-SYNC-002).
  Future<void> enqueueGroup({
    required String profileId,
    required String groupId,
    required List<OutboxInsert> operations,
    required int snapshotEpoch,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    final int count = operations.length;
    for (int index = 0; index < count; index += 1) {
      final OutboxInsert op = operations[index];
      await db
          .into(db.outboxMutations)
          .insert(
            OutboxMutationsCompanion.insert(
              operationId: op.operationId,
              profileId: profileId,
              groupId: groupId,
              groupIndex: index,
              groupCount: count,
              entityType: op.entityType,
              entityId: op.entityId,
              opKind: op.opKind,
              changedFields: Value<String?>(op.changedFields),
              baseRowVersion: Value<int?>(op.baseRowVersion),
              baseFieldVersions: Value<String?>(op.baseFieldVersions),
              snapshotEpoch: snapshotEpoch,
              payload: op.payload,
              nextAttemptUtc: nowUtc,
              state: SyncWriteState.pending,
              createdAtUtc: nowUtc,
              updatedAtUtc: nowUtc,
            ),
          );
    }
  }

  Future<List<OutboxOperation>> groupOperations(
    String profileId,
    String groupId,
  ) async {
    scope.ensureActive();
    final List<OutboxMutationRow> rows =
        await (db.select(db.outboxMutations)
              ..where(
                (OutboxMutations t) =>
                    t.profileId.equals(profileId) & t.groupId.equals(groupId),
              )
              ..orderBy(<OrderClauseGenerator<OutboxMutations>>[
                (OutboxMutations t) => OrderingTerm.asc(t.groupIndex),
              ]))
            .get();
    return rows.map(_map).toList(growable: false);
  }

  /// Reads the full ordered operations of [groupId] with the payload/base
  /// metadata needed to rebuild a wire semantic group for push. Ordered by the
  /// 0-based group index so the reconstructed group preserves the enqueue order
  /// (parent-before-child).
  Future<List<OutboxPushOperation>> groupPushOperations(
    String profileId,
    String groupId,
  ) async {
    scope.ensureActive();
    final List<OutboxMutationRow> rows =
        await (db.select(db.outboxMutations)
              ..where(
                (OutboxMutations t) =>
                    t.profileId.equals(profileId) & t.groupId.equals(groupId),
              )
              ..orderBy(<OrderClauseGenerator<OutboxMutations>>[
                (OutboxMutations t) => OrderingTerm.asc(t.groupIndex),
              ]))
            .get();
    return rows
        .map(
          (OutboxMutationRow row) => OutboxPushOperation(
            operationId: row.operationId,
            groupIndex: row.groupIndex,
            entityType: row.entityType,
            entityId: row.entityId,
            opKind: row.opKind,
            payload: row.payload,
            changedFields: row.changedFields,
            baseRowVersion: row.baseRowVersion,
            baseFieldVersions: row.baseFieldVersions,
            snapshotEpoch: row.snapshotEpoch,
          ),
        )
        .toList(growable: false);
  }

  /// Advances all operations in [groupId] to [state].
  Future<int> advanceGroup({
    required String profileId,
    required String groupId,
    required String state,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    return (db.update(db.outboxMutations)..where(
          (OutboxMutations t) =>
              t.profileId.equals(profileId) & t.groupId.equals(groupId),
        ))
        .write(
          OutboxMutationsCompanion(
            state: Value<String>(state),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  /// Restart recovery: returns interrupted `in_flight` operations to `pending`
  /// with a fresh attempt time so the idempotent group is retried.
  Future<int> resetInterrupted(String profileId, int nowUtc) async {
    scope.ensureActive();
    return (db.update(db.outboxMutations)..where(
          (OutboxMutations t) =>
              t.profileId.equals(profileId) &
              t.state.equals(SyncWriteState.inFlight),
        ))
        .write(
          OutboxMutationsCompanion(
            state: const Value<String>(SyncWriteState.pending),
            nextAttemptUtc: Value<int>(nowUtc),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  /// True when every operation in [groupId] has reached [state].
  Future<bool> groupAllInState({
    required String profileId,
    required String groupId,
    required String state,
  }) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS total, '
          'SUM(CASE WHEN state = ? THEN 1 ELSE 0 END) AS matched '
          'FROM outbox_mutations WHERE profile_id = ? AND group_id = ?',
          variables: <Variable<Object>>[
            Variable<String>(state),
            Variable<String>(profileId),
            Variable<String>(groupId),
          ],
        )
        .get();
    final int total = rows.single.data['total'] as int;
    final int matched = (rows.single.data['matched'] as int?) ?? 0;
    return total > 0 && total == matched;
  }

  /// Removes every operation for [groupId]; used by journaled pruning once the
  /// group is durably accepted and retention has elapsed.
  Future<int> deleteGroup(String profileId, String groupId) async {
    scope.ensureActive();
    return (db.delete(db.outboxMutations)..where(
          (OutboxMutations t) =>
              t.profileId.equals(profileId) & t.groupId.equals(groupId),
        ))
        .go();
  }

  /// Returns the distinct pending group ids ready to send, oldest first.
  Future<List<String>> readyGroups(String profileId, int nowUtc) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT group_id, MIN(next_attempt_utc) AS na FROM outbox_mutations '
          'WHERE profile_id = ? AND state = ? AND next_attempt_utc <= ? '
          'GROUP BY group_id ORDER BY na, group_id',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            const Variable<String>(SyncWriteState.pending),
            Variable<int>(nowUtc),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['group_id'] as String)
        .toList(growable: false);
  }

  OutboxOperation _map(OutboxMutationRow row) => OutboxOperation(
    operationId: row.operationId,
    groupId: row.groupId,
    entityType: row.entityType,
    entityId: row.entityId,
    opKind: row.opKind,
    state: row.state,
  );
}

/// Persists and reads durable, pullable conflict artifacts (task 9.3;
/// R-SYNC-004, R-NOTE-007, data-model.md §6).
///
/// An artifact is uniquely keyed by `(profile_id, remote_artifact_id)`, so
/// re-pulling or re-recording the same artifact never duplicates it — writes
/// are idempotent. A losing value can always be recovered from a stored
/// artifact until it is resolved plus its retention window expires; retention
/// never removes an unresolved artifact.
final class SyncConflictRepository extends SyncWriteRepository {
  SyncConflictRepository(super.db, super.scope);

  Future<int> openCount(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sync_conflicts "
          "WHERE profile_id = ? AND status = 'open'",
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  /// Durably records [artifact] for [profileId]. Idempotent: a second insert of
  /// the same `(profile_id, remote_artifact_id)` is ignored, so a duplicate
  /// pull or replay cannot create a second row. [id] is the local primary key
  /// used only for the first insert.
  Future<void> upsertArtifact({
    required String profileId,
    required String id,
    required ConflictArtifact artifact,
  }) async {
    scope.ensureActive();
    await db
        .into(db.syncConflicts)
        .insert(
          SyncConflictsCompanion.insert(
            id: id,
            profileId: profileId,
            remoteArtifactId: artifact.remoteArtifactId,
            entityType: artifact.entityType,
            entityId: artifact.entityId,
            fields: jsonEncode(artifact.fields),
            baseSnapshot: Value<String?>(
              _encodeSnapshot(artifact.baseSnapshot),
            ),
            localSnapshot: Value<String?>(
              _encodeSnapshot(artifact.localSnapshot),
            ),
            remoteSnapshot: Value<String?>(
              _encodeSnapshot(artifact.remoteSnapshot),
            ),
            policy: artifact.policy.wire,
            status: artifact.status.wire,
            resolution: Value<String?>(artifact.resolution),
            retainedUntilUtc: Value<int?>(artifact.retainedUntilUtc),
            createdAtUtc: artifact.createdAtUtc,
            resolvedAtUtc: Value<int?>(artifact.resolvedAtUtc),
          ),
          onConflict: DoNothing(
            target: <Column<Object>>[
              db.syncConflicts.profileId,
              db.syncConflicts.remoteArtifactId,
            ],
          ),
        );
  }

  /// Reads one artifact by its durable id, or null when absent.
  Future<ConflictArtifact?> findByArtifactId(
    String profileId,
    String remoteArtifactId,
  ) async {
    scope.ensureActive();
    final SyncConflictRow? row =
        await (db.select(db.syncConflicts)..where(
              (SyncConflicts t) =>
                  t.profileId.equals(profileId) &
                  t.remoteArtifactId.equals(remoteArtifactId),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapArtifact(row);
  }

  /// Lists every open (unresolved) artifact for [profileId], oldest first, so
  /// the UI can surface recoverable losing values.
  Future<List<ConflictArtifact>> listOpen(String profileId) async {
    scope.ensureActive();
    final List<SyncConflictRow> rows =
        await (db.select(db.syncConflicts)
              ..where(
                (SyncConflicts t) =>
                    t.profileId.equals(profileId) & t.status.equals('open'),
              )
              ..orderBy(<OrderClauseGenerator<SyncConflicts>>[
                (SyncConflicts t) => OrderingTerm.asc(t.createdAtUtc),
                (SyncConflicts t) => OrderingTerm.asc(t.remoteArtifactId),
              ]))
            .get();
    return rows.map(_mapArtifact).toList(growable: false);
  }

  /// Resolves an artifact idempotently: only an `open` row transitions, so
  /// applying the same resolution twice has no additional effect. Returns the
  /// number of rows changed (0 on a replay).
  Future<int> resolve({
    required String profileId,
    required String remoteArtifactId,
    required String resolution,
    required int resolvedAtUtc,
  }) async {
    scope.ensureActive();
    return (db.update(db.syncConflicts)..where(
          (SyncConflicts t) =>
              t.profileId.equals(profileId) &
              t.remoteArtifactId.equals(remoteArtifactId) &
              t.status.equals('open'),
        ))
        .write(
          SyncConflictsCompanion(
            status: const Value<String>('resolved'),
            resolution: Value<String?>(resolution),
            resolvedAtUtc: Value<int?>(resolvedAtUtc),
          ),
        );
  }

  static String? _encodeSnapshot(Map<String, Object?>? snapshot) =>
      snapshot == null ? null : jsonEncode(snapshot);

  static Map<String, Object?>? _decodeSnapshot(String? encoded) {
    if (encoded == null) {
      return null;
    }
    return (jsonDecode(encoded) as Map<String, Object?>);
  }

  ConflictArtifact _mapArtifact(SyncConflictRow row) => ConflictArtifact(
    remoteArtifactId: row.remoteArtifactId,
    entityType: row.entityType,
    entityId: row.entityId,
    policy: ConflictPolicyKind.fromWire(row.policy),
    fields: (jsonDecode(row.fields) as List<Object?>).cast<String>(),
    createdAtUtc: row.createdAtUtc,
    baseSnapshot: _decodeSnapshot(row.baseSnapshot),
    localSnapshot: _decodeSnapshot(row.localSnapshot),
    remoteSnapshot: _decodeSnapshot(row.remoteSnapshot),
    status: ConflictStatus.fromWire(row.status),
    resolution: row.resolution,
    retainedUntilUtc: row.retainedUntilUtc,
    resolvedAtUtc: row.resolvedAtUtc,
  );
}

/// A full outbox operation ready to be reconstructed into a wire semantic
/// group for push (carries the serialized payload and base version metadata).
final class OutboxPushOperation {
  const OutboxPushOperation({
    required this.operationId,
    required this.groupIndex,
    required this.entityType,
    required this.entityId,
    required this.opKind,
    required this.payload,
    required this.snapshotEpoch,
    this.changedFields,
    this.baseRowVersion,
    this.baseFieldVersions,
  });

  final String operationId;
  final int groupIndex;
  final String entityType;
  final String entityId;
  final String opKind;
  final String payload;
  final int snapshotEpoch;
  final String? changedFields;
  final int? baseRowVersion;
  final String? baseFieldVersions;
}

/// Insert descriptor for one outbox operation.
final class OutboxInsert {
  const OutboxInsert({
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
  final String opKind;
  final String payload;
  final String? changedFields;
  final int? baseRowVersion;
  final String? baseFieldVersions;
}

/// Reads and advances the per-backend ordered pull cursor (`sync_cursors`,
/// data-model.md §6, R-SYNC-003).
///
/// The cursor is the single durable record of "how far pull has progressed"
/// for a `(profile_id, backend)`. It advances only inside the one pull
/// transaction that also applies the page's effects, records applied
/// operations, and writes durable conflicts/dirty markers — so a failure at any
/// point rolls the cursor back with everything else (Property 4).
final class SyncCursorRepository extends SyncWriteRepository {
  SyncCursorRepository(super.db, super.scope);

  /// Reads the stored cursor for `(profileId, backend)`, or `null` when pull
  /// has never advanced for that backend. A `null` result is equivalent to
  /// [SyncCursor.initial] for decision purposes.
  Future<SyncCursor?> read(String profileId, String backend) async {
    scope.ensureActive();
    final SyncCursorRow? row =
        await (db.select(db.syncCursors)..where(
              (SyncCursors t) =>
                  t.profileId.equals(profileId) & t.backend.equals(backend),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return SyncCursor(
      epoch: SnapshotEpoch(row.epoch),
      serverSeq: ServerSeq(row.serverSeq ?? 0),
      opaqueToken: row.cursor,
    );
  }

  /// Persists [cursor] for `(profileId, backend)`. Upsert on the primary key so
  /// advancing an existing cursor updates it in place; the first advance
  /// inserts it. Called only from within the pull transaction.
  Future<void> save({
    required String profileId,
    required String backend,
    required SyncCursor cursor,
    required int updatedAtUtc,
    String? deviceId,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT INTO sync_cursors '
      '(profile_id, backend, device_id, epoch, cursor, server_seq, '
      'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id, backend) DO UPDATE SET '
      'device_id = excluded.device_id, epoch = excluded.epoch, '
      'cursor = excluded.cursor, server_seq = excluded.server_seq, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        profileId,
        backend,
        deviceId,
        cursor.epoch.value,
        cursor.opaqueToken,
        cursor.serverSeq.value,
        updatedAtUtc,
      ],
    );
  }
}

/// Records durable, idempotent applied-operation markers (`applied_operations`,
/// data-model.md §6, R-SYNC-003).
///
/// Each inbound change records `(profile_id, backend, operation_id)` exactly
/// once. Re-recording the same operation is ignored, so re-pulling or replaying
/// a page never creates a duplicate marker — the record backs idempotent pull
/// apply together with idempotent feature appliers.
final class AppliedOperationRepository extends SyncWriteRepository {
  AppliedOperationRepository(super.db, super.scope);

  /// True when the operation has already been recorded as applied.
  Future<bool> isApplied({
    required String profileId,
    required String backend,
    required String operationId,
  }) async {
    scope.ensureActive();
    final AppliedOperationRow? row =
        await (db.select(db.appliedOperations)..where(
              (AppliedOperations t) =>
                  t.profileId.equals(profileId) &
                  t.backend.equals(backend) &
                  t.operationId.equals(operationId),
            ))
            .getSingleOrNull();
    return row != null;
  }

  /// Records [operationId] as applied. Idempotent: a second record of the same
  /// `(profile_id, backend, operation_id)` is ignored.
  Future<void> record({
    required String profileId,
    required String backend,
    required String operationId,
    required String changeId,
    required String checksum,
    required int appliedAtUtc,
    required int epoch,
  }) async {
    scope.ensureActive();
    await db
        .into(db.appliedOperations)
        .insert(
          AppliedOperationsCompanion.insert(
            profileId: profileId,
            backend: backend,
            operationId: operationId,
            changeId: changeId,
            checksum: checksum,
            appliedAtUtc: appliedAtUtc,
            epoch: epoch,
          ),
          onConflict: DoNothing(
            target: <Column<Object>>[
              db.appliedOperations.profileId,
              db.appliedOperations.backend,
              db.appliedOperations.operationId,
            ],
          ),
        );
  }

  Future<int> count(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM applied_operations WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['n'] as int;
  }
}
