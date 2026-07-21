/// Search domain value types (R-SEARCH-001..003, R-NOTE-004).
///
/// A [SearchDocumentDraft] is the projector's typed contribution for one
/// searchable entity: a display title, a normalized searchable body, and the
/// versioned weighting inputs. The infrastructure maps a draft onto the unified
/// `search_documents` row and the external-content `search_fts` index using the
/// stable integer row id allocated from `fts_rowids`.
library;

/// The versioned relative weighting of a document's fields (design.md §14:
/// `title > body > code/metadata`). The version is stored on every
/// `search_documents` row so a weighting change is a rebuildable migration
/// rather than a silent reinterpretation.
final class SearchWeighting {
  const SearchWeighting({
    required this.version,
    required this.titleWeight,
    required this.bodyWeight,
  });

  /// The V1 weighting: titles rank well above body text; code/metadata is
  /// folded into the body at a lower textual density by the projector.
  static const SearchWeighting v1 = SearchWeighting(
    version: 1,
    titleWeight: 10,
    bodyWeight: 1,
  );

  final int version;
  final double titleWeight;
  final double bodyWeight;
}

/// A projector's typed contribution for a single searchable entity.
///
/// [title] is the primary display/rank field; [body] is the normalized
/// searchable text (Markdown flattened, code/metadata appended at lower
/// weight). A projector returns `null` instead of a draft when the entity no
/// longer exists or has been tombstoned, which removes/hides its document
/// transactionally.
final class SearchDocumentDraft {
  const SearchDocumentDraft({
    required this.entityType,
    required this.entityId,
    required this.title,
    required this.body,
    required this.sourceRevision,
    this.weighting = SearchWeighting.v1,
  });

  final String entityType;
  final String entityId;
  final String title;
  final String body;

  /// The source row revision this document was derived from, recorded so a
  /// stale reconciliation pass can be detected.
  final int sourceRevision;
  final SearchWeighting weighting;
}

/// A single grouped search hit returned to the presentation layer.
///
/// [titleHighlighted]/[bodySnippet] carry the safe highlight markers produced
/// by FTS5; the raw matched text is never interpreted as query syntax. [score]
/// is the BM25 rank (lower is a better match).
final class SearchHit {
  const SearchHit({
    required this.entityType,
    required this.entityId,
    required this.title,
    required this.titleHighlighted,
    required this.bodySnippet,
    required this.score,
  });

  final String entityType;
  final String entityId;
  final String title;
  final String titleHighlighted;
  final String bodySnippet;
  final double score;
}

/// A type-grouped block of hits (R-SEARCH-002 "group by type").
final class SearchResultGroup {
  const SearchResultGroup({required this.entityType, required this.hits});

  final String entityType;
  final List<SearchHit> hits;
}

/// The full result of a global search: hits grouped by entity type, best match
/// first within each group, groups ordered by their best hit.
final class SearchResults {
  const SearchResults({required this.groups, required this.totalHits});

  static const SearchResults empty = SearchResults(
    groups: <SearchResultGroup>[],
    totalHits: 0,
  );

  final List<SearchResultGroup> groups;
  final int totalHits;

  bool get isEmpty => totalHits == 0;
}
