import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/domain/search_document.dart';

/// Application query facade for global search (R-SEARCH-002, R-SEARCH-003).
///
/// This is the stable boundary presentation and other features use to query the
/// unified index; the Drift-backed implementation lives in infrastructure.
/// Results are grouped by entity type and each hit carries the entity type/id
/// so the caller can open the record's local canonical projection
/// (R-SEARCH-002). Search is fully local, so results are available offline
/// (R-SEARCH-003).
abstract interface class SearchService {
  /// Searches within [profileId] for [query], optionally restricted to [types].
  /// [prefix] enables as-you-type matching on the final token; [limit] bounds
  /// the number of hits scored.
  Future<SearchResults> search(
    ProfileId profileId,
    String query, {
    Set<String>? types,
    bool prefix,
    int limit,
  });
}
