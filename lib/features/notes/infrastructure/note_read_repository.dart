import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';
import 'package:forge/features/notes/domain/note_link.dart';
import 'package:forge/features/notes/domain/note_repository.dart';
import 'package:forge/features/notes/infrastructure/note_mapper.dart';

/// Drift-backed read model for notes (R-NOTE-002).
///
/// Reads run against the active local generation, which is the client source of
/// truth (design.md §8). Structured filters compose with AND; free-text is a
/// simple `LIKE` fallback — unified FTS text search is served by the search
/// read model (R-NOTE-004).
final class NoteReadRepository implements NoteRepository {
  NoteReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<Note?> findById(ProfileId profileId, NoteId noteId) async {
    final NoteRow? row =
        await (_db.select(_db.notes)..where(
              (Notes t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(noteId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : NoteMapper.fromRow(row);
  }

  @override
  Future<List<Note>> query(ProfileId profileId, NoteQuery filter) async {
    final _WhereClause where = _buildWhere(profileId, filter);
    final String order = filter.onlyDeleted
        ? 'ORDER BY deleted_at_utc DESC, id DESC'
        : 'ORDER BY pinned DESC, updated_at_utc DESC, id DESC';
    final String limit = filter.limit == null ? '' : 'LIMIT ${filter.limit}';
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM notes WHERE ${where.sql} $order $limit',
          variables: where.variables,
        )
        .get();
    return rows
        .map((QueryRow r) => NoteMapper.fromRow(_db.notes.map(r.data)))
        .toList(growable: false);
  }

  @override
  Future<List<Note>> view(
    ProfileId profileId,
    NoteViewKind kind, {
    LifeAreaId? lifeAreaId,
  }) {
    switch (kind) {
      case NoteViewKind.all:
        return query(
          profileId,
          NoteQuery(lifeAreaId: lifeAreaId, archived: false),
        );
      case NoteViewKind.pinned:
        return query(
          profileId,
          NoteQuery(lifeAreaId: lifeAreaId, pinned: true, archived: false),
        );
      case NoteViewKind.archived:
        return query(
          profileId,
          NoteQuery(lifeAreaId: lifeAreaId, archived: true),
        );
      case NoteViewKind.trash:
        return query(
          profileId,
          NoteQuery(lifeAreaId: lifeAreaId, onlyDeleted: true),
        );
    }
  }

  @override
  Future<String?> lastRank(ProfileId profileId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT rank FROM notes WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[Variable<String>(profileId.value)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['rank'] as String;
  }

  @override
  Future<List<String>> tagIdsFor(ProfileId profileId, NoteId noteId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT tag_id FROM entity_tags '
          "WHERE profile_id = ? AND entity_type = 'note' AND entity_id = ? "
          'ORDER BY tag_id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(noteId.value),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['tag_id'] as String)
        .toList(growable: false);
  }

  @override
  Future<List<Note>> findByNormalizedTitle(
    ProfileId profileId,
    String normalizedTitle,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM notes WHERE profile_id = ? '
          'AND normalized_title = ? AND deleted_at_utc IS NULL '
          'ORDER BY id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(normalizeNoteTitle(normalizedTitle)),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => NoteMapper.fromRow(_db.notes.map(r.data)))
        .toList(growable: false);
  }

  /// The outgoing links from [noteId], ordered by source position (R-NOTE-003).
  Future<List<NoteLink>> outgoingLinks(
    ProfileId profileId,
    NoteId noteId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM note_links WHERE profile_id = ? AND source_note_id = ? '
          'ORDER BY source_start ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(noteId.value),
          ],
        )
        .get();
    return rows.map(_linkFromData).toList(growable: false);
  }

  /// The links that resolve to [noteId] (backlinks, R-NOTE-003). Only links
  /// explicitly resolved to this note are inbound backlinks; ambiguous and
  /// unresolved links carry no `target_note_id` and are excluded.
  Future<List<NoteLink>> backlinks(ProfileId profileId, NoteId noteId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM note_links WHERE profile_id = ? AND target_note_id = ? '
          'ORDER BY source_note_id ASC, source_start ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(noteId.value),
          ],
        )
        .get();
    return rows.map(_linkFromData).toList(growable: false);
  }

  /// The links in note [noteId] that need an explicit selection because more
  /// than one live note shares the target title (R-NOTE-003). The editor
  /// surfaces these for the user to resolve rather than silently binding.
  Future<List<NoteLink>> ambiguousLinks(
    ProfileId profileId,
    NoteId noteId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          "SELECT * FROM note_links WHERE profile_id = ? AND source_note_id = ? "
          "AND resolution = 'ambiguous' ORDER BY source_start ASC",
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(noteId.value),
          ],
        )
        .get();
    return rows.map(_linkFromData).toList(growable: false);
  }

  /// The candidate live notes an ambiguous link may be bound to: every live
  /// note whose normalized title equals the link's normalized target, excluding
  /// the link's own source note (R-NOTE-003). Presented for explicit selection.
  Future<List<Note>> candidatesForLink(
    ProfileId profileId,
    String linkId,
  ) async {
    final List<QueryRow> linkRows = await _db
        .customSelect(
          'SELECT source_note_id, normalized_target FROM note_links '
          'WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(linkId),
          ],
        )
        .get();
    if (linkRows.isEmpty) {
      return const <Note>[];
    }
    final String sourceNoteId =
        linkRows.single.data['source_note_id'] as String;
    final String normalizedTarget =
        linkRows.single.data['normalized_target'] as String;
    final List<Note> matches = await findByNormalizedTitle(
      profileId,
      normalizedTarget,
    );
    return matches
        .where((Note n) => n.id.value != sourceNoteId)
        .toList(growable: false);
  }

  /// The entity links a note owns, i.e. the tasks/goals/etc. it references
  /// (R-NOTE-002).
  Future<List<NoteEntityLink>> entityLinksOf(
    ProfileId profileId,
    NoteId noteId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM entity_links WHERE profile_id = ? AND from_type = ? '
          'AND from_id = ? AND relation = ? ORDER BY to_type ASC, rank ASC, '
          'to_id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            const Variable<String>(noteEntityFromType),
            Variable<String>(noteId.value),
            const Variable<String>(noteEntityRelation),
          ],
        )
        .get();
    return rows.map(_entityLinkFromData).toList(growable: false);
  }

  /// The notes that reference the entity `(targetType, targetId)` — the reverse
  /// navigation from a task/goal/etc. back to its linked notes (R-NOTE-002).
  Future<List<NoteEntityLink>> notesLinkingTo(
    ProfileId profileId,
    String targetType,
    String targetId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM entity_links WHERE profile_id = ? AND relation = ? '
          'AND to_type = ? AND to_id = ? ORDER BY from_id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            const Variable<String>(noteEntityRelation),
            Variable<String>(targetType),
            Variable<String>(targetId),
          ],
        )
        .get();
    return rows.map(_entityLinkFromData).toList(growable: false);
  }

  NoteLink _linkFromData(QueryRow r) => NoteLink(
    id: r.data['id'] as String,
    profileId: ProfileId(r.data['profile_id'] as String),
    sourceNoteId: NoteId(r.data['source_note_id'] as String),
    targetTitle: r.data['target_title'] as String,
    normalizedTarget: r.data['normalized_target'] as String,
    label: r.data['label'] as String,
    sourceStart: r.data['source_start'] as int,
    sourceEnd: r.data['source_end'] as int,
    targetNoteId: r.data['target_note_id'] == null
        ? null
        : NoteId(r.data['target_note_id'] as String),
    resolution: WikiLinkResolution.fromWire(r.data['resolution'] as String?),
  );

  NoteEntityLink _entityLinkFromData(QueryRow r) => NoteEntityLink(
    id: r.data['id'] as String,
    profileId: ProfileId(r.data['profile_id'] as String),
    noteId: NoteId(r.data['from_id'] as String),
    targetType: r.data['to_type'] as String,
    targetId: r.data['to_id'] as String,
    rank: r.data['rank'] as String,
    createdAtUtc: r.data['created_at_utc'] as int,
  );

  _WhereClause _buildWhere(ProfileId profileId, NoteQuery f) {
    final List<String> clauses = <String>['profile_id = ?'];
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
    ];

    if (f.onlyDeleted) {
      clauses.add('deleted_at_utc IS NOT NULL');
    } else if (!f.includeDeleted) {
      clauses.add('deleted_at_utc IS NULL');
    }

    if (f.lifeAreaId != null) {
      clauses.add('life_area_id = ?');
      vars.add(Variable<String>(f.lifeAreaId!.value));
    }
    if (f.pinned != null) {
      clauses.add('pinned = ?');
      vars.add(Variable<int>(f.pinned! ? 1 : 0));
    }
    if (f.archived != null) {
      clauses.add(
        f.archived! ? 'archived_at_utc IS NOT NULL' : 'archived_at_utc IS NULL',
      );
    }
    if (f.tagId != null) {
      clauses.add(
        'id IN (SELECT entity_id FROM entity_tags '
        "WHERE profile_id = ? AND entity_type = 'note' AND tag_id = ?)",
      );
      vars
        ..add(Variable<String>(profileId.value))
        ..add(Variable<String>(f.tagId!));
    }
    if (f.titleContains != null && f.titleContains!.isNotEmpty) {
      clauses.add("title LIKE ? ESCAPE '\\'");
      vars.add(Variable<String>('%${_escapeLike(f.titleContains!)}%'));
    }

    return _WhereClause(clauses.join(' AND '), vars);
  }

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

final class _WhereClause {
  const _WhereClause(this.sql, this.variables);

  final String sql;
  final List<Variable<Object>> variables;
}
