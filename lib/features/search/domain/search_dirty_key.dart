/// The projection name and key convention for the unified search projection.
///
/// A semantic write emits a `search` dirty projection marker for every
/// searchable source change (design.md §5/§14). Because the unified index spans
/// every entity type, the marker key encodes both the entity type and id as
/// `"<entityType>:<entityId>"` so the projector registry can route the marker
/// to the one projector that owns that type. The id itself is opaque and may
/// contain no `:` (Forge ids are `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`), so the
/// first `:` unambiguously separates the segments.
library;

abstract final class SearchDirtyKey {
  /// The projection name shared by every searchable entity type.
  static const String projection = 'search';

  /// Encodes a routing key for [entityType]/[entityId].
  static String encode(String entityType, String entityId) =>
      '$entityType:$entityId';

  /// Decodes a routing key, or `null` when it is not a valid `type:id` pair.
  static SearchDirtyRef? decode(String key) {
    final int sep = key.indexOf(':');
    if (sep <= 0 || sep >= key.length - 1) {
      return null;
    }
    return SearchDirtyRef(
      entityType: key.substring(0, sep),
      entityId: key.substring(sep + 1),
    );
  }
}

/// A decoded `search` dirty projection reference.
final class SearchDirtyRef {
  const SearchDirtyRef({required this.entityType, required this.entityId});

  final String entityType;
  final String entityId;
}
