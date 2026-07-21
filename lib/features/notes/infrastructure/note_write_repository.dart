import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_link.dart';
import 'package:forge/features/notes/domain/note_rank.dart';
import 'package:forge/features/notes/infrastructure/note_mapper.dart';

/// Transaction-scoped write access to `notes`, `note_links`, and the note's
/// `entity_tags`.
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes.
final class NoteWriteRepository {
  NoteWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  Future<Note?> find(String profileId, String noteId) async {
    scope.ensureActive();
    final NoteRow? row =
        await (db.select(db.notes)..where(
              (Notes t) => t.profileId.equals(profileId) & t.id.equals(noteId),
            ))
            .getSingleOrNull();
    return row == null ? null : NoteMapper.fromRow(row);
  }

  Future<void> insert(Note note, {required String normalizedTitle}) async {
    scope.ensureActive();
    await db
        .into(db.notes)
        .insert(NoteMapper.toInsert(note, normalizedTitle: normalizedTitle));
  }

  Future<void> update(Note note, {required String normalizedTitle}) async {
    scope.ensureActive();
    await (db.update(db.notes)..where(
          (Notes t) =>
              t.profileId.equals(note.profileId.value) &
              t.id.equals(note.id.value),
        ))
        .write(NoteMapper.toUpdate(note, normalizedTitle: normalizedTitle));
  }

  /// The highest existing note rank for [profileId] among live notes.
  Future<NoteRank?> lastRank(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM notes WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return NoteRank(rows.single.data['rank'] as String);
  }

  Future<void> attachTag({
    required String profileId,
    required String noteId,
    required String tagId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT OR IGNORE INTO entity_tags '
      '(profile_id, entity_type, entity_id, tag_id, created_at_utc) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[profileId, 'note', noteId, tagId, nowUtc],
    );
  }

  /// Replaces the outgoing wiki-link set for [sourceNoteId] with [links],
  /// maintaining the link rows transactionally with the note write
  /// (R-NOTE-003, R-NOTE-004).
  Future<void> replaceLinks({
    required String profileId,
    required String sourceNoteId,
    required List<NoteLink> links,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'DELETE FROM note_links WHERE profile_id = ? AND source_note_id = ?',
      <Object?>[profileId, sourceNoteId],
    );
    for (final NoteLink link in links) {
      await db.customStatement(
        'INSERT INTO note_links '
        '(id, profile_id, source_note_id, target_note_id, target_title, '
        'normalized_target, label, source_start, source_end, resolution, '
        'created_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          link.id,
          profileId,
          sourceNoteId,
          link.targetNoteId?.value,
          link.targetTitle,
          link.normalizedTarget,
          link.label,
          link.sourceStart,
          link.sourceEnd,
          link.resolution.wire,
          nowUtc,
        ],
      );
    }
  }

  /// The normalized title of note [noteId] regardless of trash state, or null
  /// when no such row exists. Used by inbound link re-resolution to recompute
  /// every link that referenced this note's title.
  Future<String?> normalizedTitleOf(String profileId, String noteId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT normalized_title FROM notes '
          'WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(noteId),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return rows.single.data['normalized_title'] as String?;
  }

  /// Re-resolves every outgoing link whose `normalized_target` equals
  /// [normalizedTarget], recomputing each against the current set of live notes
  /// (R-NOTE-003). Deterministic single-match binds, zero matches become
  /// `unresolved`, multiple matches become `ambiguous`. A link never resolves
  /// to its own source note.
  ///
  /// This is the shared maintenance step invoked in the same commit as the
  /// triggering write when a note is created, renamed, trashed, or restored.
  /// Returns the number of link rows whose resolution changed.
  Future<int> reResolveByNormalizedTarget(
    String profileId,
    String normalizedTarget,
  ) async {
    scope.ensureActive();
    final List<String> candidates = await idsByNormalizedTitle(
      profileId,
      normalizedTarget,
    );
    final List<QueryRow> linkRows = await db
        .customSelect(
          'SELECT id, source_note_id, target_note_id, resolution '
          'FROM note_links WHERE profile_id = ? AND normalized_target = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(normalizedTarget),
          ],
        )
        .get();

    int changed = 0;
    for (final QueryRow row in linkRows) {
      final String linkId = row.data['id'] as String;
      final String sourceNoteId = row.data['source_note_id'] as String;
      final List<String> visible = candidates
          .where((String id) => id != sourceNoteId)
          .toList(growable: false);
      final WikiLinkResolution resolution = WikiLinkResolution.classify(
        visible,
      );
      final String? target = resolution == WikiLinkResolution.resolved
          ? visible.single
          : null;
      final String? currentTarget = row.data['target_note_id'] as String?;
      final String currentResolution = row.data['resolution'] as String;
      if (currentResolution == resolution.wire && currentTarget == target) {
        continue; // Already correct — leave untouched.
      }
      await db.customUpdate(
        'UPDATE note_links SET target_note_id = ?, resolution = ? '
        'WHERE id = ?',
        variables: <Variable<Object>>[
          if (target == null)
            const Variable<String>(null)
          else
            Variable<String>(target),
          Variable<String>(resolution.wire),
          Variable<String>(linkId),
        ],
        updateKind: UpdateKind.update,
      );
      changed += 1;
    }
    return changed;
  }

  /// Re-resolves inbound links after note [targetNoteId] is hard-purged: every
  /// link that still pointed at the now-gone note is recomputed by its own
  /// stored `normalized_target` so it deterministically drops to `unresolved`
  /// (or rebinds if another note shares the title). Returns rows changed.
  Future<int> reResolveDanglingTarget(
    String profileId,
    String targetNoteId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT DISTINCT normalized_target FROM note_links '
          'WHERE profile_id = ? AND target_note_id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(targetNoteId),
          ],
        )
        .get();
    int changed = 0;
    for (final QueryRow row in rows) {
      changed += await reResolveByNormalizedTarget(
        profileId,
        row.data['normalized_target'] as String,
      );
    }
    return changed;
  }

  /// A single link row by id for the explicit ambiguity-resolution command, or
  /// null when it does not belong to [profileId].
  Future<NoteLink?> findLink(String profileId, String linkId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT * FROM note_links WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(linkId),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    final Map<String, Object?> d = rows.single.data;
    return NoteLink(
      id: d['id'] as String,
      profileId: ProfileId(d['profile_id'] as String),
      sourceNoteId: NoteId(d['source_note_id'] as String),
      targetTitle: d['target_title'] as String,
      normalizedTarget: d['normalized_target'] as String,
      label: d['label'] as String,
      sourceStart: d['source_start'] as int,
      sourceEnd: d['source_end'] as int,
      targetNoteId: d['target_note_id'] == null
          ? null
          : NoteId(d['target_note_id'] as String),
      resolution: WikiLinkResolution.fromWire(d['resolution'] as String?),
    );
  }

  /// Binds link [linkId] to the explicitly chosen [chosenNoteId] (R-NOTE-003
  /// ambiguity resolution). Returns the number of rows changed (0 when the link
  /// was already bound to that target).
  Future<int> bindLinkTarget(
    String profileId,
    String linkId,
    String chosenNoteId,
  ) async {
    scope.ensureActive();
    return db.customUpdate(
      "UPDATE note_links SET target_note_id = ?, resolution = 'resolved' "
      'WHERE profile_id = ? AND id = ?',
      variables: <Variable<Object>>[
        Variable<String>(chosenNoteId),
        Variable<String>(profileId),
        Variable<String>(linkId),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// True when a live (non-deleted) note [noteId] exists under [profileId].
  Future<bool> liveNoteExists(String profileId, String noteId) async {
    scope.ensureActive();
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

  /// The ids of live notes whose normalized title equals [normalizedTitle],
  /// used for single-match `[[wiki-link]]` resolution. Zero or multiple matches
  /// leave a link unresolved (ambiguity handling is task 5.2).
  Future<List<String>> idsByNormalizedTitle(
    String profileId,
    String normalizedTitle,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM notes WHERE profile_id = ? '
          'AND normalized_title = ? AND deleted_at_utc IS NULL ORDER BY id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(normalizedTitle),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  /// The ids of every non-deleted note for [profileId], for the search rebuild
  /// path.
  Future<List<String>> activeIds(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM notes WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY id ASC',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }
}
