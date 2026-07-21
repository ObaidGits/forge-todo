import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';

/// Durable store for a profile's saved search filters (R-SEARCH-002).
///
/// Saved filters are a local, non-sync preference collection: they are written
/// durably and transactionally to the active local generation and are fully
/// reconstructible on startup (R-GEN-001), following the same
/// settings-key/value pattern as the Today layout preference rather than the
/// sync-eligible command bus.
abstract interface class SavedFiltersStore {
  /// Loads the saved filters for [profileId], in stable insertion order. Never
  /// throws for a missing/empty value; returns an empty list instead.
  Future<List<SavedSearchFilter>> load(ProfileId profileId);

  /// Persists the complete [filters] list for [profileId], replacing any prior
  /// value in a single durable write.
  Future<void> save(ProfileId profileId, List<SavedSearchFilter> filters);
}
