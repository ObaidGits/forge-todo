import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Notes schema (data-model.md §3 "Notes and files"; R-NOTE-001, R-NOTE-002,
// R-NOTE-003, R-NOTE-004, R-NOTE-005).
// ---------------------------------------------------------------------------
//
// `notes` is a direct-area owner: every note carries `(profile_id,
// life_area_id)` and references `life_areas(profile_id, id)`. The UTF-8
// Markdown `body` is the single canonical source of truth (R-NOTE-001); other
// features reference a note by id and never duplicate its text (R-TASK-010).
//
// `note_drafts` is the encrypted durable draft journal (R-NOTE-005): it is an
// inherited-area child of a note and is local-only (never replicated). The
// draft body is stored encrypted at rest; the exact base revision is pinned so
// a later three-way merge (R-NOTE-007) has the exact base.
//
// `note_links` is the profile-owned, area-free outgoing wiki-link set
// maintained transactionally with the note write (R-NOTE-004).

/// Canonical Markdown notes.
@DataClassName('NoteRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_notes_profile_id ON notes (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_notes_area_id '
  'ON notes (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_notes_pinned_updated '
  'ON notes (profile_id, pinned, updated_at_utc, id) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex(name: 'ix_notes_area', columns: {#profileId, #lifeAreaId, #rank})
@TableIndex(name: 'ix_notes_hash', columns: {#profileId, #contentHash})
@TableIndex(
  name: 'ix_notes_norm_title',
  columns: {#profileId, #normalizedTitle},
)
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get title => text()();

  /// Case/whitespace-folded title used for `[[wiki-link]]` resolution.
  TextColumn get normalizedTitle => text()();

  /// The canonical UTF-8 Markdown body (R-NOTE-001).
  TextColumn get body => text()();
  TextColumn get contentHash => text()();
  BoolColumn get pinned => boolean().withDefault(const Constant<bool>(false))();
  IntColumn get archivedAtUtc => integer().nullable()();
  TextColumn get rank => text()();
  IntColumn get revision => integer().withDefault(const Constant<int>(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, life_area_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, life_area_id) REFERENCES life_areas (profile_id, id)',
    'CHECK (revision >= 1)',
  ];
}

/// Encrypted durable draft journal (R-NOTE-005). One current draft per note.
@DataClassName('NoteDraftRow')
@TableIndex(
  name: 'ix_note_drafts_updated',
  columns: {#profileId, #updatedAtUtc},
)
class NoteDrafts extends Table {
  TextColumn get profileId => text()();
  TextColumn get noteId => text()();

  /// The exact note revision the draft was based on (R-NOTE-005, R-NOTE-007).
  IntColumn get baseRevision => integer()();

  /// The draft Markdown body, encrypted at rest. OS restoration data contains
  /// no note content; the plaintext lives only in editor memory and here in
  /// encrypted form (R-NOTE-005).
  TextColumn get encryptedBody => text()();
  TextColumn get recoveryStatus => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, noteId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, note_id) REFERENCES notes (profile_id, id)',
    "CHECK (recovery_status IN ('active', 'awaiting_recovery'))",
  ];
}

/// Outgoing `[[wiki-link]]` set maintained transactionally with the note write
/// (R-NOTE-003, R-NOTE-004).
@DataClassName('NoteLinkRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_note_links_position '
  'ON note_links (profile_id, source_note_id, source_start)',
)
@TableIndex(name: 'ix_note_links_source', columns: {#profileId, #sourceNoteId})
@TableIndex(
  name: 'ix_note_links_backlink',
  columns: {#profileId, #targetNoteId},
)
@TableIndex(
  name: 'ix_note_links_target_title',
  columns: {#profileId, #normalizedTarget},
)
class NoteLinks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get sourceNoteId => text()();

  /// Resolved target note id, or null when unresolved/ambiguous (R-NOTE-003).
  TextColumn get targetNoteId => text().nullable()();
  TextColumn get targetTitle => text()();
  TextColumn get normalizedTarget => text()();
  TextColumn get label => text()();
  IntColumn get sourceStart => integer()();
  IntColumn get sourceEnd => integer()();

  /// Explicit resolution state: `resolved`, `ambiguous`, or `unresolved`
  /// (R-NOTE-003). Ambiguous links MUST prompt an explicit selection rather
  /// than silently bind; `target_note_id` is set only when `resolution` is
  /// `resolved`. Additive at schema v5.
  TextColumn get resolution =>
      text().withDefault(const Constant<String>('unresolved'))();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, source_note_id) REFERENCES notes (profile_id, id)',
    'CHECK (source_end >= source_start)',
    "CHECK (resolution IN ('resolved', 'ambiguous', 'unresolved'))",
    'CHECK ((resolution = \'resolved\') = (target_note_id IS NOT NULL))',
  ];
}
