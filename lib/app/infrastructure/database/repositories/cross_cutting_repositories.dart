import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';

/// Base for a transaction-scoped repository over the core schema.
///
/// Every query runs against [db]; while a Drift transaction is active Drift
/// routes those queries to the transaction executor automatically. The [scope]
/// guard rejects any use after the transaction completes (design.md §5).
abstract base class CrossCuttingRepository {
  CrossCuttingRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;
}

/// A durable command receipt row (R-GEN-005).
final class StoredReceipt {
  const StoredReceipt({
    required this.requestHash,
    required this.resultCode,
    required this.payloadVersion,
    required this.commitSeq,
    this.resultPayload,
  });

  final String requestHash;
  final String resultCode;
  final String? resultPayload;
  final int payloadVersion;
  final int commitSeq;
}

/// Reads and writes `command_receipts` keyed by `(profile_id, command_id)`.
final class CommandReceiptRepository extends CrossCuttingRepository {
  CommandReceiptRepository(super.db, super.scope);

  Future<StoredReceipt?> find(String profileId, String commandId) async {
    scope.ensureActive();
    final CommandReceiptRow? row =
        await (db.select(db.commandReceipts)..where(
              (CommandReceipts t) =>
                  t.profileId.equals(profileId) & t.commandId.equals(commandId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return StoredReceipt(
      requestHash: row.requestHash,
      resultCode: row.resultCode,
      resultPayload: row.resultPayload,
      payloadVersion: row.payloadVersion,
      commitSeq: row.commitSeq,
    );
  }

  Future<void> insert({
    required String profileId,
    required String commandId,
    required String requestHash,
    required String resultCode,
    required int payloadVersion,
    required int commitSeq,
    required int createdAtUtc,
    String? resultPayload,
  }) async {
    scope.ensureActive();
    await db
        .into(db.commandReceipts)
        .insert(
          CommandReceiptsCompanion.insert(
            profileId: profileId,
            commandId: commandId,
            requestHash: requestHash,
            resultCode: resultCode,
            resultPayload: Value<String?>(resultPayload),
            payloadVersion: payloadVersion,
            commitSeq: commitSeq,
            createdAtUtc: createdAtUtc,
          ),
        );
  }
}

/// Appends monotonic `commit_log` rows.
final class CommitLogRepository extends CrossCuttingRepository {
  CommitLogRepository(super.db, super.scope);

  /// Peeks the next commit sequence for [profileId] without consuming it.
  Future<int> nextCommitSeq(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(commit_seq), 0) AS m FROM commit_log '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return (rows.single.data['m'] as int) + 1;
  }

  Future<void> append({
    required String profileId,
    required int commitSeq,
    required String commandId,
    required String writeOrigin,
    required int committedAtUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.commitLog)
        .insert(
          CommitLogCompanion.insert(
            profileId: profileId,
            commitSeq: commitSeq,
            commandId: commandId,
            writeOrigin: writeOrigin,
            committedAtUtc: committedAtUtc,
          ),
        );
  }
}

/// Appends `activity_events`.
final class ActivityRepository extends CrossCuttingRepository {
  ActivityRepository(super.db, super.scope);

  Future<void> append({
    required String id,
    required String profileId,
    required String eventType,
    required String entityType,
    required String entityId,
    required int occurredAtUtc,
    required int payloadVersion,
    required int commitSeq,
    String? commandId,
    String? payload,
  }) async {
    scope.ensureActive();
    await db
        .into(db.activityEvents)
        .insert(
          ActivityEventsCompanion.insert(
            id: id,
            profileId: profileId,
            eventType: eventType,
            entityType: entityType,
            entityId: entityId,
            occurredAtUtc: occurredAtUtc,
            payloadVersion: payloadVersion,
            commandId: Value<String?>(commandId),
            commitSeq: commitSeq,
            payload: Value<String?>(payload),
          ),
        );
  }
}

/// Writes and reconciles durable projection dirty markers.
final class ProjectionDirtyRepository extends CrossCuttingRepository {
  ProjectionDirtyRepository(super.db, super.scope);

  /// Marks a projection dirty at [sourceCommitSeq]. Re-marking the same
  /// projection/key advances its source watermark and resets attempt state.
  Future<void> mark({
    required String profileId,
    required String projection,
    required String projectionKey,
    required int sourceCommitSeq,
    required int updatedAtUtc,
  }) async {
    scope.ensureActive();
    // Re-marking advances the source watermark and resets attempt state. The
    // primary key (profile_id, projection, projection_key) drives the upsert.
    await db.customStatement(
      'INSERT INTO projection_dirty '
      '(profile_id, projection, projection_key, source_commit_seq, attempts, '
      'last_error, updated_at_utc) VALUES (?, ?, ?, ?, 0, NULL, ?) '
      'ON CONFLICT(profile_id, projection, projection_key) DO UPDATE SET '
      'source_commit_seq = excluded.source_commit_seq, attempts = 0, '
      'last_error = NULL, updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        profileId,
        projection,
        projectionKey,
        sourceCommitSeq,
        updatedAtUtc,
      ],
    );
  }

  /// Clears a reconciled marker once its projection watermark reaches the
  /// recorded source commit sequence.
  Future<void> clear({
    required String profileId,
    required String projection,
    required String projectionKey,
    required int reconciledCommitSeq,
  }) async {
    scope.ensureActive();
    await (db.delete(db.projectionDirty)..where(
          (ProjectionDirty t) =>
              t.profileId.equals(profileId) &
              t.projection.equals(projection) &
              t.projectionKey.equals(projectionKey) &
              t.sourceCommitSeq.isSmallerOrEqualValue(reconciledCommitSeq),
        ))
        .go();
  }

  Future<int> pendingCount(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM projection_dirty WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  /// Records a failed reconciliation attempt for a marker: increments its
  /// attempt count and stores [error] without clearing the marker so it is
  /// retried on the next startup/resume pass.
  Future<void> recordFailure({
    required String profileId,
    required String projection,
    required String projectionKey,
    required String error,
    required int updatedAtUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'UPDATE projection_dirty SET attempts = attempts + 1, last_error = ?, '
      'updated_at_utc = ? WHERE profile_id = ? AND projection = ? AND '
      'projection_key = ?',
      <Object?>[error, updatedAtUtc, profileId, projection, projectionKey],
    );
  }
}
