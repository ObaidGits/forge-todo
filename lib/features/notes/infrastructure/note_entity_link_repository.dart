import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';

/// Transaction-scoped write access to note→entity links in the polymorphic
/// `entity_links` table (R-NOTE-002, R-GEN-002).
///
/// SQLite cannot foreign-key across entity types, so ownership is validated in
/// the writing transaction against a centralized owner registry
/// ([ownerTables]) that maps each recognized target type to the physical table
/// carrying `(profile_id, id)` (data-model §1). Because every existence check
/// is scoped to the link's profile, a target id belonging to another profile
/// is never found and the link is rejected — cross-profile references cannot be
/// created locally (R-GEN-002).
final class NoteEntityLinkRepository {
  NoteEntityLinkRepository(this.db, this.scope, this.ownerTables);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Recognized target type → owner table name. Only types whose owning feature
  /// is present appear here; unavailable types are rejected until they register
  /// (e.g. goals/roadmaps/Learning Resources/habits land in later waves).
  final Map<String, String> ownerTables;

  /// Links note [noteId] to the target `(targetType, targetId)`.
  ///
  /// Validates that the owning note is live, the target type is a recognized
  /// and available note-entity target, and the target exists under the same
  /// profile before inserting an idempotent `entity_links` row.
  Future<NoteEntityLinkOutcome> link({
    required String id,
    required String profileId,
    required String noteId,
    required String targetType,
    required String targetId,
    required String rank,
    required int nowUtc,
  }) async {
    scope.ensureActive();

    if (!NoteEntityTargetType.all.contains(targetType)) {
      return NoteEntityLinkOutcome.targetTypeUnknown;
    }
    if (!await _liveNoteExists(profileId, noteId)) {
      return NoteEntityLinkOutcome.noteMissing;
    }
    final String? table = ownerTables[targetType];
    if (table == null) {
      return NoteEntityLinkOutcome.targetTypeUnavailable;
    }
    if (!await _targetExists(table, profileId, targetId)) {
      // Not found under this profile — includes another profile's id
      // (cross-profile rejection, R-GEN-002).
      return NoteEntityLinkOutcome.targetMissing;
    }

    final int inserted = await db.customUpdate(
      'INSERT OR IGNORE INTO entity_links '
      '(id, profile_id, from_type, from_id, relation, to_type, to_id, rank, '
      'created_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: <Variable<Object>>[
        Variable<String>(id),
        Variable<String>(profileId),
        const Variable<String>(noteEntityFromType),
        Variable<String>(noteId),
        const Variable<String>(noteEntityRelation),
        Variable<String>(targetType),
        Variable<String>(targetId),
        Variable<String>(rank),
        Variable<int>(nowUtc),
      ],
      updateKind: UpdateKind.insert,
    );
    return inserted == 0
        ? NoteEntityLinkOutcome.alreadyLinked
        : NoteEntityLinkOutcome.linked;
  }

  /// Removes the note→entity link tuple if present. Returns the rows deleted
  /// (0 when the link did not exist, keeping unlink idempotent).
  Future<int> unlink({
    required String profileId,
    required String noteId,
    required String targetType,
    required String targetId,
  }) async {
    scope.ensureActive();
    return db.customUpdate(
      'DELETE FROM entity_links WHERE profile_id = ? AND from_type = ? '
      'AND from_id = ? AND relation = ? AND to_type = ? AND to_id = ?',
      variables: <Variable<Object>>[
        Variable<String>(profileId),
        const Variable<String>(noteEntityFromType),
        Variable<String>(noteId),
        const Variable<String>(noteEntityRelation),
        Variable<String>(targetType),
        Variable<String>(targetId),
      ],
      updateKind: UpdateKind.delete,
    );
  }

  Future<bool> _liveNoteExists(String profileId, String noteId) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM notes WHERE profile_id = ? AND id = ? '
          'AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(noteId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<bool> _targetExists(
    String table,
    String profileId,
    String targetId,
  ) async {
    // [table] comes only from the controlled [ownerTables] registry; it is
    // never user input, so interpolating the identifier is safe.
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM $table WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(targetId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }
}
