import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';

/// Current soft-deletion state of an entity row.
final class TrashState {
  const TrashState({required this.exists, required this.deletedAtUtc});

  /// A row with the requested id exists for the profile.
  final bool exists;

  /// The soft-deletion instant, or null when the row is live.
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;
}

/// Generic soft-delete / restore / hard-delete over any table carrying
/// `(profile_id, id, deleted_at_utc)` (R-GEN-003).
///
/// The table name is taken from a validated [TrashableEntity] descriptor, so
/// the same kernel serves every feature aggregate without per-table code. All
/// mutations run inside the caller's transaction; the shared [scope] rejects
/// use after the transaction completes.
final class TrashRepository extends CrossCuttingRepository {
  TrashRepository(super.db, super.scope);

  Future<TrashState> stateOf(
    TrashableEntity entity,
    String profileId,
    String entityId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT deleted_at_utc FROM ${entity.tableName} '
          'WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityId),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return const TrashState(exists: false, deletedAtUtc: null);
    }
    return TrashState(
      exists: true,
      deletedAtUtc: rows.single.data['deleted_at_utc'] as int?,
    );
  }

  /// Marks a live row deleted. Returns the number of rows affected; a row that
  /// is already soft-deleted is left untouched so Undo/soft-delete stay
  /// idempotent.
  Future<int> softDelete(
    TrashableEntity entity,
    String profileId,
    String entityId,
    int deletedAtUtc,
  ) async {
    scope.ensureActive();
    return db.customUpdate(
      'UPDATE ${entity.tableName} SET deleted_at_utc = ? '
      'WHERE profile_id = ? AND id = ? AND deleted_at_utc IS NULL',
      variables: <Variable<Object>>[
        Variable<int>(deletedAtUtc),
        Variable<String>(profileId),
        Variable<String>(entityId),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Clears the tombstone, preserving the row's id and every link/child that
  /// referenced it (R-GEN-003 restore).
  Future<int> restore(
    TrashableEntity entity,
    String profileId,
    String entityId,
  ) async {
    scope.ensureActive();
    return db.customUpdate(
      'UPDATE ${entity.tableName} SET deleted_at_utc = NULL '
      'WHERE profile_id = ? AND id = ? AND deleted_at_utc IS NOT NULL',
      variables: <Variable<Object>>[
        Variable<String>(profileId),
        Variable<String>(entityId),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Permanently removes the row. Only ever reached after a preview,
  /// confirmation, and block re-check (R-GEN-003 hard purge).
  Future<int> hardDelete(
    TrashableEntity entity,
    String profileId,
    String entityId,
  ) async {
    scope.ensureActive();
    return db.customUpdate(
      'DELETE FROM ${entity.tableName} WHERE profile_id = ? AND id = ?',
      variables: <Variable<Object>>[
        Variable<String>(profileId),
        Variable<String>(entityId),
      ],
      updateKind: UpdateKind.delete,
    );
  }

  /// Returns the ids of rows whose trash retention elapsed at or before
  /// [purgeBeforeUtc]. Reporting only — never deletes (R-GEN-003).
  Future<List<String>> eligibleForPurge(
    TrashableEntity entity,
    String profileId,
    int purgeBeforeUtc,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM ${entity.tableName} '
          'WHERE profile_id = ? AND deleted_at_utc IS NOT NULL '
          'AND deleted_at_utc <= ? ORDER BY deleted_at_utc, id',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<int>(purgeBeforeUtc),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }
}

/// Counts the durable obligations that block hard purge for one entity
/// (R-GEN-003): pending outbox operations, open conflicts, unexpired remote
/// retention, and in-flight file-journal state.
final class PurgeGuardRepository extends CrossCuttingRepository {
  PurgeGuardRepository(super.db, super.scope);

  Future<int> pendingOutboxCount(
    String profileId,
    String entityType,
    String entityId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM outbox_mutations '
          'WHERE profile_id = ? AND entity_type = ? AND entity_id = ? '
          'AND state IN (?, ?)',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
            const Variable<String>(SyncWriteState.pending),
            const Variable<String>(SyncWriteState.inFlight),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  Future<int> openConflictCount(
    String profileId,
    String entityType,
    String entityId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sync_conflicts "
          "WHERE profile_id = ? AND entity_type = ? AND entity_id = ? "
          "AND status = 'open'",
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  /// Unexpired remote retention: an accepted-but-unpruned tombstone still in
  /// the outbox (retained until journaled pruning confirms the window elapsed)
  /// or a conflict artifact whose retention has not yet passed [nowUtc].
  Future<int> retentionCount(
    String profileId,
    String entityType,
    String entityId,
    int nowUtc,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT '
          '(SELECT COUNT(*) FROM outbox_mutations '
          ' WHERE profile_id = ? AND entity_type = ? AND entity_id = ? '
          ' AND state = ?) + '
          '(SELECT COUNT(*) FROM sync_conflicts '
          ' WHERE profile_id = ? AND entity_type = ? AND entity_id = ? '
          ' AND retained_until_utc IS NOT NULL '
          ' AND retained_until_utc > ?) AS n',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
            const Variable<String>(SyncWriteState.acknowledged),
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
            Variable<int>(nowUtc),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  Future<int> pendingFileOpsCount(
    String profileId,
    String entityType,
    String entityId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM file_journal "
          "WHERE profile_id = ? AND owner_entity_type = ? "
          "AND owner_entity_id = ? AND state IN ('pending', 'in_progress')",
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }
}

/// Durable file-operation journal writes (data-model §3). Managed-file staging
/// and deletion are journaled here before the filesystem mutation so a crash
/// leaves a restart-safe cleanup record, and hard purge can observe in-flight
/// file work as a block.
final class FileJournalRepository extends CrossCuttingRepository {
  FileJournalRepository(super.db, super.scope);

  Future<void> record({
    required String id,
    required String profileId,
    required String operation,
    required String state,
    required int nowUtc,
    String? ownerEntityType,
    String? ownerEntityId,
    String? stagedPathToken,
    String? finalPathToken,
    String? expectedHash,
    int? expectedBytes,
  }) async {
    scope.ensureActive();
    await db
        .into(db.fileJournal)
        .insert(
          FileJournalCompanion.insert(
            id: id,
            profileId: profileId,
            operation: operation,
            state: state,
            ownerEntityType: Value<String?>(ownerEntityType),
            ownerEntityId: Value<String?>(ownerEntityId),
            stagedPathToken: Value<String?>(stagedPathToken),
            finalPathToken: Value<String?>(finalPathToken),
            expectedHash: Value<String?>(expectedHash),
            expectedBytes: Value<int?>(expectedBytes),
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
  }

  /// Advances a journal entry to [state] (e.g. `done`, `failed`, `cleaned`).
  Future<int> advance({
    required String id,
    required String state,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    return (db.update(
      db.fileJournal,
    )..where((FileJournal t) => t.id.equals(id))).write(
      FileJournalCompanion(
        state: Value<String>(state),
        updatedAtUtc: Value<int>(nowUtc),
      ),
    );
  }
}
