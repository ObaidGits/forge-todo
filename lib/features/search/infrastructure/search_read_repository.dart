import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/domain/search_query.dart';
import 'package:forge/features/search/infrastructure/search_fts.dart';

/// Drift-backed [SearchService] over the unified search index (R-SEARCH-002,
/// R-SEARCH-003).
///
/// Queries run against the active local generation, so results are available
/// offline. Free text is sanitized into a safe FTS5 MATCH expression that
/// cannot be broken by malicious query syntax; profile/type filters and the
/// tombstone flag are applied on `search_documents`. Results carry safe
/// highlight markers and are grouped by entity type, best match first.
final class SearchReadRepository implements SearchService {
  SearchReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<SearchResults> search(
    ProfileId profileId,
    String query, {
    Set<String>? types,
    bool prefix = true,
    int limit = 50,
  }) async {
    final String? match = SearchQuerySanitizer.toMatchExpression(
      query,
      prefix: prefix,
    );
    if (match == null) {
      return SearchResults.empty;
    }

    final List<String> clauses = <String>[
      '${SearchFts.table} MATCH ?',
      'd.profile_id = ?',
      'd.deleted = 0',
    ];
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(match),
      Variable<String>(profileId.value),
    ];

    if (types != null && types.isNotEmpty) {
      final String placeholders = List<String>.filled(
        types.length,
        '?',
      ).join(', ');
      clauses.add('d.entity_type IN ($placeholders)');
      for (final String type in types) {
        vars.add(Variable<String>(type));
      }
    }

    // BM25 column weights apply the versioned `title > body` ranking (a lower
    // score is a better match). FTS5 requires literal weight arguments, so the
    // v1 weighting is expressed as constants; the per-document stored weights
    // record the version so a weighting change is a rebuildable migration.
    final String sql =
        'SELECT d.entity_type AS entity_type, d.entity_id AS entity_id, '
        'd.title AS title, '
        'highlight(${SearchFts.table}, ${SearchFts.titleColumn}, ?, ?) '
        'AS title_hl, '
        'snippet(${SearchFts.table}, ${SearchFts.bodyColumn}, ?, ?, ?, 32) '
        'AS body_snip, '
        'bm25(${SearchFts.table}, '
        '${SearchWeighting.v1.titleWeight}, ${SearchWeighting.v1.bodyWeight}) '
        'AS score '
        'FROM ${SearchFts.table} '
        'JOIN ${SearchFts.contentTable} d '
        'ON d.doc_rowid = ${SearchFts.table}.rowid '
        'WHERE ${clauses.join(' AND ')} '
        'ORDER BY score ASC, d.entity_type ASC, d.entity_id ASC '
        'LIMIT ?';

    final List<Variable<Object>> allVars = <Variable<Object>>[
      Variable<String>(SearchFts.highlightOpen),
      Variable<String>(SearchFts.highlightClose),
      Variable<String>(SearchFts.highlightOpen),
      Variable<String>(SearchFts.highlightClose),
      const Variable<String>('…'),
      ...vars,
      Variable<int>(limit),
    ];

    final List<QueryRow> rows = await _db
        .customSelect(sql, variables: allVars)
        .get();

    final List<SearchHit> hits = rows
        .map(
          (QueryRow r) => SearchHit(
            entityType: r.data['entity_type'] as String,
            entityId: r.data['entity_id'] as String,
            title: r.data['title'] as String,
            titleHighlighted: r.data['title_hl'] as String? ?? '',
            bodySnippet: r.data['body_snip'] as String? ?? '',
            score: (r.data['score'] as num).toDouble(),
          ),
        )
        .toList(growable: false);

    return _group(hits);
  }

  /// Groups [hits] by entity type, preserving best-match ordering within each
  /// group and ordering groups by their best hit (R-SEARCH-002).
  SearchResults _group(List<SearchHit> hits) {
    if (hits.isEmpty) {
      return SearchResults.empty;
    }
    final Map<String, List<SearchHit>> byType = <String, List<SearchHit>>{};
    final List<String> order = <String>[];
    for (final SearchHit hit in hits) {
      final List<SearchHit> bucket = byType.putIfAbsent(hit.entityType, () {
        order.add(hit.entityType);
        return <SearchHit>[];
      });
      bucket.add(hit);
    }
    final List<SearchResultGroup> groups = order
        .map(
          (String type) =>
              SearchResultGroup(entityType: type, hits: byType[type]!),
        )
        .toList(growable: false);
    return SearchResults(groups: groups, totalHits: hits.length);
  }
}
