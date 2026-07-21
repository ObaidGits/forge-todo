import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Unified search schema (data-model.md §3 "Notes and files"; design.md §14;
// R-SEARCH-001..003, R-NOTE-004).
// ---------------------------------------------------------------------------
//
// The search index is profile-owned, area-free, and local-only (it never
// serializes to the wire). Three objects cooperate:
//
//  * `fts_rowids`      — maps `(profile_id, entity_type, entity_id)` to a stable
//                        positive integer row id. The mapping is allocated once
//                        and never reused, so a document's FTS row id is stable
//                        across edits, tombstones, and full rebuilds.
//  * `search_documents`— the unified document per entity: display title,
//                        normalized searchable body, versioned weighting, source
//                        revision and a tombstone flag. `doc_rowid` equals the
//                        stable integer id and is the external-content row id.
//  * `search_fts`      — an FTS5 external-content index over `search_documents`
//                        (title, body) created as a virtual table outside the
//                        Drift table set (see `search_fts.dart`).
//
// Both concrete tables are ordinary Drift tables so they participate in the
// ownership-classification completeness check; the FTS5 virtual table is
// created by DDL because Drift has no virtual-table DSL.

/// Stable integer row-id allocation for the unified FTS index.
@DataClassName('FtsRowidRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_fts_rowids_entity '
  'ON fts_rowids (profile_id, entity_type, entity_id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_fts_rowids_rowid ON fts_rowids (fts_rowid)',
)
class FtsRowids extends Table {
  TextColumn get profileId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();

  /// The stable positive integer used as the `search_fts` / `search_documents`
  /// row id. Globally unique so it is a valid FTS5 external-content row id.
  IntColumn get ftsRowid => integer()();

  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    profileId,
    entityType,
    entityId,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'CHECK (fts_rowid > 0)',
  ];
}

/// The unified searchable document per entity (one row per searchable entity).
@DataClassName('SearchDocumentRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_search_documents_entity '
  'ON search_documents (profile_id, entity_type, entity_id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_search_documents_rowid '
  'ON search_documents (doc_rowid)',
)
@TableIndex(
  name: 'ix_search_documents_type',
  columns: {#profileId, #entityType, #deleted},
)
class SearchDocuments extends Table {
  /// The stable integer id (equal to `fts_rowids.fts_rowid`) used as the
  /// external-content row id for `search_fts`.
  IntColumn get docRowid => integer()();

  TextColumn get profileId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();

  /// Versioned weighting inputs (design.md §14 `title > body > code/metadata`).
  IntColumn get weightVersion => integer()();
  RealColumn get titleWeight => real()();
  RealColumn get bodyWeight => real()();

  /// The source revision this document was derived from.
  IntColumn get sourceRevision => integer()();

  /// Tombstone flag: a hidden document is excluded from results and removed from
  /// the FTS index while keeping its stable row-id mapping.
  BoolColumn get deleted =>
      boolean().withDefault(const Constant<bool>(false))();

  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{docRowid};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'CHECK (doc_rowid > 0)',
  ];
}
