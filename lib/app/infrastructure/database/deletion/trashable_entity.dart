/// Describes a soft-deletable domain entity for the generic deletion kernel
/// (R-GEN-003).
///
/// Feature waves register their trashable aggregates (`task`, `note`, `goal`,
/// ...) with a [TrashRegistry]; the Wave 2 kernel is deliberately table-driven
/// so soft-delete, restore, purge-eligibility, and hard purge work uniformly
/// before any domain table exists. Every registered table MUST carry the
/// `profile_id`, `id`, and `deleted_at_utc` columns the kernel manipulates.
library;

/// Immutable descriptor for one soft-deletable entity type.
final class TrashableEntity {
  TrashableEntity({
    required this.entityType,
    required this.tableName,
    this.syncEligible = true,
  }) {
    _validateIdentifier(entityType, 'entityType');
    _validateIdentifier(tableName, 'tableName');
  }

  /// Stable entity-type discriminator used in the outbox, conflicts, activity,
  /// and file-journal rows (e.g. `task`, `note`, `life_area`).
  final String entityType;

  /// The physical table carrying `(profile_id, id, deleted_at_utc)`.
  final String tableName;

  /// Whether ordinary deletion produces a replicated tombstone. Operational,
  /// non-replicated entities skip outbox enqueue (data-model §1).
  final bool syncEligible;

  /// Guards against SQL identifier injection. Descriptors come from controlled
  /// registration code, but the kernel interpolates [tableName] into SQL so the
  /// identifier is validated defensively.
  static void _validateIdentifier(String value, String field) {
    if (!_identifier.hasMatch(value)) {
      throw ArgumentError.value(value, field, 'Invalid SQL identifier.');
    }
  }

  static final RegExp _identifier = RegExp(r'^[a-z][a-z0-9_]{0,62}$');
}

/// Resolves an [entityType] to its registered [TrashableEntity] descriptor.
///
/// The registry is assembled at the composition root from every feature that
/// owns soft-deletable aggregates; the deletion services reject entity types
/// that were never registered.
final class TrashRegistry {
  TrashRegistry(Iterable<TrashableEntity> entities)
    : _byType = <String, TrashableEntity>{
        for (final TrashableEntity entity in entities)
          entity.entityType: entity,
      } {
    if (_byType.length != entities.length) {
      throw ArgumentError('Duplicate entity type in TrashRegistry.');
    }
  }

  final Map<String, TrashableEntity> _byType;

  /// Returns the descriptor for [entityType] or throws [StateError] when the
  /// type was never registered.
  TrashableEntity require(String entityType) {
    final TrashableEntity? entity = _byType[entityType];
    if (entity == null) {
      throw StateError('No trashable entity registered for "$entityType".');
    }
    return entity;
  }

  bool contains(String entityType) => _byType.containsKey(entityType);

  Iterable<TrashableEntity> get all => _byType.values;
}
