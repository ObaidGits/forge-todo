import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/infrastructure/search_fts.dart';

/// Transaction-scoped maintenance of the unified search index.
///
/// All three objects — `fts_rowids`, `search_documents` and the `search_fts`
/// external-content index — are mutated through the active transaction so the
/// domain row, the document, the FTS index and the dirty watermark advance
/// atomically (data-model §4). The stable integer row id is allocated once per
/// entity and reused for every later edit, tombstone and rebuild.
final class SearchWriteRepository {
  SearchWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Upserts the document described by [draft] and refreshes its FTS row.
  Future<void> upsert(
    SearchDocumentDraft draft, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    final int rowid = await _rowidFor(
      profileId: profileId,
      entityType: draft.entityType,
      entityId: draft.entityId,
      nowUtc: nowUtc,
    );
    final _ExistingDoc? existing = await _existingDoc(rowid);

    // Remove the previous FTS entry (if the document was indexed) before
    // writing the new one. External-content deletes require the old values.
    if (existing != null && !existing.deleted) {
      await _ftsDelete(rowid, existing.title, existing.body);
    }

    await db.customStatement(
      'INSERT INTO search_documents '
      '(doc_rowid, profile_id, entity_type, entity_id, title, body, '
      'weight_version, title_weight, body_weight, source_revision, deleted, '
      'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?) '
      'ON CONFLICT(doc_rowid) DO UPDATE SET '
      'title = excluded.title, body = excluded.body, '
      'weight_version = excluded.weight_version, '
      'title_weight = excluded.title_weight, '
      'body_weight = excluded.body_weight, '
      'source_revision = excluded.source_revision, deleted = 0, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        rowid,
        profileId,
        draft.entityType,
        draft.entityId,
        draft.title,
        draft.body,
        draft.weighting.version,
        draft.weighting.titleWeight,
        draft.weighting.bodyWeight,
        draft.sourceRevision,
        nowUtc,
      ],
    );

    await _ftsInsert(rowid, draft.title, draft.body);
  }

  /// Hides the document for [entityType]/[entityId] and removes it from the FTS
  /// index, preserving the stable row-id mapping so a later re-add is stable.
  Future<void> tombstone({
    required String profileId,
    required String entityType,
    required String entityId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    final int? rowid = await _lookupRowid(profileId, entityType, entityId);
    if (rowid == null) {
      return;
    }
    final _ExistingDoc? existing = await _existingDoc(rowid);
    if (existing == null || existing.deleted) {
      return;
    }
    await _ftsDelete(rowid, existing.title, existing.body);
    await (db.update(
      db.searchDocuments,
    )..where((SearchDocuments t) => t.docRowid.equals(rowid))).write(
      SearchDocumentsCompanion(
        deleted: const Value<bool>(true),
        updatedAtUtc: Value<int>(nowUtc),
      ),
    );
  }

  /// Clears every document and FTS entry for [profileId] (used by the source
  /// rebuild path before re-projecting from source rows).
  Future<void> clearProfile(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT doc_rowid, title, body, deleted FROM search_documents '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    for (final QueryRow row in rows) {
      final int rowid = row.data['doc_rowid'] as int;
      final bool deleted = (row.data['deleted'] as int) != 0;
      if (!deleted) {
        await _ftsDelete(
          rowid,
          row.data['title'] as String,
          row.data['body'] as String,
        );
      }
    }
    await (db.delete(
      db.searchDocuments,
    )..where((SearchDocuments t) => t.profileId.equals(profileId))).go();
    await (db.delete(
      db.ftsRowids,
    )..where((FtsRowids t) => t.profileId.equals(profileId))).go();
  }

  // ---- internals ----------------------------------------------------------

  Future<int> _rowidFor({
    required String profileId,
    required String entityType,
    required String entityId,
    required int nowUtc,
  }) async {
    final int? existing = await _lookupRowid(profileId, entityType, entityId);
    if (existing != null) {
      return existing;
    }
    final List<QueryRow> maxRows = await db
        .customSelect('SELECT COALESCE(MAX(fts_rowid), 0) AS m FROM fts_rowids')
        .get();
    final int next = (maxRows.single.data['m'] as int) + 1;
    await db.customStatement(
      'INSERT INTO fts_rowids '
      '(profile_id, entity_type, entity_id, fts_rowid, created_at_utc) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[profileId, entityType, entityId, next, nowUtc],
    );
    return next;
  }

  Future<int?> _lookupRowid(
    String profileId,
    String entityType,
    String entityId,
  ) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT fts_rowid FROM fts_rowids '
          'WHERE profile_id = ? AND entity_type = ? AND entity_id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(entityType),
            Variable<String>(entityId),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['fts_rowid'] as int;
  }

  Future<_ExistingDoc?> _existingDoc(int rowid) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT title, body, deleted FROM search_documents '
          'WHERE doc_rowid = ?',
          variables: <Variable<Object>>[Variable<int>(rowid)],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    final QueryRow row = rows.single;
    return _ExistingDoc(
      title: row.data['title'] as String,
      body: row.data['body'] as String,
      deleted: (row.data['deleted'] as int) != 0,
    );
  }

  Future<void> _ftsInsert(int rowid, String title, String body) async {
    await db.customStatement(
      'INSERT INTO ${SearchFts.table}(rowid, title, body) VALUES (?, ?, ?)',
      <Object?>[rowid, title, body],
    );
  }

  Future<void> _ftsDelete(int rowid, String title, String body) async {
    await db.customStatement(
      'INSERT INTO ${SearchFts.table}(${SearchFts.table}, rowid, title, body) '
      "VALUES ('delete', ?, ?, ?)",
      <Object?>[rowid, title, body],
    );
  }
}

final class _ExistingDoc {
  const _ExistingDoc({
    required this.title,
    required this.body,
    required this.deleted,
  });

  final String title;
  final String body;
  final bool deleted;
}
