import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/application/saved_filters_store.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';
import 'package:forge/features/search/domain/search_document.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them. The
// search feature owns its own seams so it never imports another feature's
// presentation or infrastructure (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> searchProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The unified search query facade. Null until wired.
final Provider<SearchService?> searchServiceProvider = Provider<SearchService?>(
  (Ref ref) => null,
);

/// The durable saved-filters store. Null until wired.
final Provider<SavedFiltersStore?> savedFiltersStoreProvider =
    Provider<SavedFiltersStore?>((Ref ref) => null);

/// Whether the search stack is wired at all (used for the empty/unavailable
/// distinction in the UI).
final Provider<bool> searchConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(searchProfileProvider) != null &&
      ref.watch(searchServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Query + type-filter state (R-SEARCH-002).
// ---------------------------------------------------------------------------

/// The current free-text query. A [Notifier] rather than a raw state provider
/// so applying a saved filter and typing share one authority.
final class SearchQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final NotifierProvider<SearchQueryController, String> searchQueryProvider =
    NotifierProvider<SearchQueryController, String>(SearchQueryController.new);

/// The set of entity types the search is scoped to; empty means "all types".
final class SearchTypesController extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void toggle(String type) {
    final Set<String> next = <String>{...state};
    if (!next.remove(type)) {
      next.add(type);
    }
    state = next;
  }

  void set(Set<String> types) => state = <String>{...types};
  void clear() => state = <String>{};
}

final NotifierProvider<SearchTypesController, Set<String>> searchTypesProvider =
    NotifierProvider<SearchTypesController, Set<String>>(
      SearchTypesController.new,
    );

/// The grouped results for the current query/type scope (R-SEARCH-001,
/// R-SEARCH-002). Reads run against the local index, so results are available
/// offline (R-SEARCH-003). An empty query yields no results without querying.
final searchResultsProvider = FutureProvider.autoDispose<SearchResults>((
  Ref ref,
) async {
  final ProfileId? profile = ref.watch(searchProfileProvider);
  final SearchService? service = ref.watch(searchServiceProvider);
  final String query = ref.watch(searchQueryProvider).trim();
  final Set<String> types = ref.watch(searchTypesProvider);
  if (profile == null || service == null || query.isEmpty) {
    return SearchResults.empty;
  }
  return service.search(
    profile,
    query,
    types: types.isEmpty ? null : types,
    prefix: true,
  );
});

// ---------------------------------------------------------------------------
// Saved filters (R-SEARCH-002 "support filters").
// ---------------------------------------------------------------------------

/// Loads and mutates the profile's saved search filters. Every change is
/// persisted durably before the list is refreshed (R-GEN-001).
final class SavedFiltersController
    extends AsyncNotifier<List<SavedSearchFilter>> {
  @override
  Future<List<SavedSearchFilter>> build() async {
    final ProfileId? profile = ref.watch(searchProfileProvider);
    final SavedFiltersStore? store = ref.watch(savedFiltersStoreProvider);
    if (profile == null || store == null) {
      return const <SavedSearchFilter>[];
    }
    return store.load(profile);
  }

  /// Saves the current query/types under [name]. Returns false when the store
  /// is unavailable, the name is blank, or the name already exists.
  Future<bool> saveCurrent({
    required String name,
    required String query,
    required Set<String> types,
  }) async {
    final ProfileId? profile = ref.read(searchProfileProvider);
    final SavedFiltersStore? store = ref.read(savedFiltersStoreProvider);
    final String trimmed = name.trim();
    if (profile == null || store == null || trimmed.isEmpty) {
      return false;
    }
    final List<SavedSearchFilter> current = await future;
    final bool exists = current.any(
      (SavedSearchFilter f) => f.name.toLowerCase() == trimmed.toLowerCase(),
    );
    if (exists) {
      return false;
    }
    final List<SavedSearchFilter> next = <SavedSearchFilter>[
      ...current,
      SavedSearchFilter(
        id: _id(),
        name: trimmed,
        query: query,
        types: <String>{...types},
      ),
    ];
    await store.save(profile, next);
    ref.invalidateSelf();
    return true;
  }

  Future<void> delete(String id) async {
    final ProfileId? profile = ref.read(searchProfileProvider);
    final SavedFiltersStore? store = ref.read(savedFiltersStoreProvider);
    if (profile == null || store == null) {
      return;
    }
    final List<SavedSearchFilter> current = await future;
    final List<SavedSearchFilter> next = current
        .where((SavedSearchFilter f) => f.id != id)
        .toList(growable: false);
    await store.save(profile, next);
    ref.invalidateSelf();
  }

  /// Applies [filter] to the live query/type scope (R-SEARCH-002 recall).
  void apply(SavedSearchFilter filter) {
    ref.read(searchQueryProvider.notifier).set(filter.query);
    ref.read(searchTypesProvider.notifier).set(filter.types);
  }

  String _id() {
    final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    final String salt = _random.nextInt(1 << 32).toRadixString(16);
    return 'filter-$micros-$salt';
  }
}

final AsyncNotifierProvider<SavedFiltersController, List<SavedSearchFilter>>
savedFiltersProvider =
    AsyncNotifierProvider<SavedFiltersController, List<SavedSearchFilter>>(
      SavedFiltersController.new,
    );

final Random _random = Random();
