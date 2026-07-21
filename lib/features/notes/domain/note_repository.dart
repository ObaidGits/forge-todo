import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note.dart';

/// Named note view (R-NOTE-002).
enum NoteViewKind {
  /// Live (non-archived, non-deleted) notes, pinned first then by recency.
  all,

  /// Pinned live notes.
  pinned,

  /// Archived notes.
  archived,

  /// Soft-deleted notes (the Trash view).
  trash,
}

/// A composable structured note filter (R-NOTE-002).
///
/// Every field is optional and combined with logical AND. Free [titleContains]
/// text is a simple substring fallback; FTS-backed text search is served by the
/// unified search read model (R-NOTE-004).
final class NoteQuery {
  const NoteQuery({
    this.lifeAreaId,
    this.tagId,
    this.pinned,
    this.archived,
    this.titleContains,
    this.includeDeleted = false,
    this.onlyDeleted = false,
    this.limit,
  });

  final LifeAreaId? lifeAreaId;
  final String? tagId;

  /// When set, filters on the pinned flag.
  final bool? pinned;

  /// When set, filters on archived state (true = only archived).
  final bool? archived;

  final String? titleContains;
  final bool includeDeleted;
  final bool onlyDeleted;
  final int? limit;
}

/// Read access to notes. Query methods run outside a write transaction and
/// return immutable domain [Note] aggregates.
abstract interface class NoteRepository {
  Future<Note?> findById(ProfileId profileId, NoteId noteId);

  Future<List<Note>> query(ProfileId profileId, NoteQuery filter);

  Future<List<Note>> view(
    ProfileId profileId,
    NoteViewKind kind, {
    LifeAreaId? lifeAreaId,
  });

  /// The highest existing note rank for [profileId], used to append at the end.
  Future<String?> lastRank(ProfileId profileId);

  /// The ids of the tags linked to [noteId] through `entity_tags`.
  Future<List<String>> tagIdsFor(ProfileId profileId, NoteId noteId);

  /// Notes whose normalized title matches [normalizedTitle] (used for
  /// `[[wiki-link]]` resolution in task 5.2). Excludes deleted notes.
  Future<List<Note>> findByNormalizedTitle(
    ProfileId profileId,
    String normalizedTitle,
  );
}
