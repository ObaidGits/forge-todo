/// A persisted, recallable search filter (R-SEARCH-002 "support filters").
///
/// A saved filter captures a query string and the set of entity types the user
/// scoped the search to, under a user-chosen [name]. It is a local preference
/// value reconstructed from durable storage, so saved searches survive restarts
/// and are available offline (R-GEN-001).
final class SavedSearchFilter {
  const SavedSearchFilter({
    required this.id,
    required this.name,
    required this.query,
    required this.types,
  });

  final String id;
  final String name;
  final String query;

  /// The entity-type discriminators the search is scoped to. An empty set means
  /// "all types".
  final Set<String> types;

  SavedSearchFilter copyWith({
    String? name,
    String? query,
    Set<String>? types,
  }) => SavedSearchFilter(
    id: id,
    name: name ?? this.name,
    query: query ?? this.query,
    types: types ?? this.types,
  );

  @override
  bool operator ==(Object other) =>
      other is SavedSearchFilter &&
      other.id == id &&
      other.name == name &&
      other.query == query &&
      _setEquals(other.types, types);

  @override
  int get hashCode =>
      Object.hash(id, name, query, Object.hashAllUnordered(types));

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
