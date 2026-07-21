/// Versioned replication manifest: the authority that classifies every entity
/// and field as replicated, local-only, or server-only and defines payload
/// transform/tombstone behavior (R-SYNC-002, data-model.md §3 `replication_
/// manifest`).
///
/// Protocol code is generated/validated against this registry. The manifest
/// drives outbox eligibility (only manifest-allowlisted commands enqueue outbox
/// work) and wire serialization (local-only fields never enter payloads). It
/// SHALL NOT register an ordinary `profiles` insert/rekey applier — remote
/// profile metadata is a special projection onto the existing local profile.
library;

/// The replication class of one entity or field.
enum ReplicationClass {
  /// Serialized to the wire and applied on other devices.
  replicated,

  /// Never leaves the device (drafts, attachment metadata, DEKs, receipts,
  /// caches, scheduler tokens, generation metadata, local profile mapping).
  localOnly,

  /// Assigned and owned by the server (server_seq, epoch, field versions, RLS
  /// data); never authored by the client and never present in domain rows
  /// except mapped sync metadata.
  serverOnly;

  static ReplicationClass fromWire(String value) => switch (value) {
    'replicated' => ReplicationClass.replicated,
    'local_only' => ReplicationClass.localOnly,
    'server_only' => ReplicationClass.serverOnly,
    _ => throw ArgumentError.value(value, 'value', 'Unknown replication class'),
  };

  String get wire => switch (this) {
    ReplicationClass.replicated => 'replicated',
    ReplicationClass.localOnly => 'local_only',
    ReplicationClass.serverOnly => 'server_only',
  };
}

/// The field wildcard denoting an entity's default classification. A per-field
/// entry overrides the wildcard for that one field.
const String kManifestFieldWildcard = '*';

/// One `(protocol_version, entity_type, field)` manifest row.
final class ManifestEntry {
  ManifestEntry({
    required this.entityType,
    required this.field,
    required this.replicationClass,
    required this.introducedVersion,
    this.protocolVersion = 2,
    this.transform,
    this.tombstonePolicy,
    this.retiredVersion,
  }) {
    if (entityType.isEmpty) {
      throw ArgumentError.value(entityType, 'entityType', 'Must not be empty.');
    }
    if (field.isEmpty) {
      throw ArgumentError.value(field, 'field', 'Must not be empty.');
    }
  }

  final int protocolVersion;
  final String entityType;

  /// A concrete field name, or [kManifestFieldWildcard] for the entity default.
  final String field;
  final ReplicationClass replicationClass;

  /// Optional payload transform identifier (e.g. unit normalization).
  final String? transform;

  /// Optional tombstone policy identifier for delete handling.
  final String? tombstonePolicy;
  final int introducedVersion;
  final int? retiredVersion;

  bool get isWildcard => field == kManifestFieldWildcard;

  bool activeAt(int version) =>
      version >= introducedVersion &&
      (retiredVersion == null || version < retiredVersion!);
}

/// Raised when the manifest is internally inconsistent, e.g. it registers an
/// ordinary `profiles` insert applier (forbidden by R-SYNC-001/§3).
final class ReplicationManifestException implements Exception {
  const ReplicationManifestException(this.reason);

  final String reason;

  @override
  String toString() => 'ReplicationManifestException: $reason';
}

/// An immutable, versioned replication manifest built from [ManifestEntry]
/// rows. Lookups resolve a field-specific entry first, then the entity's
/// wildcard default, then fall back to [localOnly] for unknown territory (the
/// safe default: never serialize what the manifest does not explicitly
/// replicate).
final class ReplicationManifest {
  ReplicationManifest(
    Iterable<ManifestEntry> entries, {
    this.protocolVersion = 2,
  }) : _entries = List<ManifestEntry>.unmodifiable(entries) {
    for (final ManifestEntry entry in _entries) {
      final _Key key = _Key(entry.entityType, entry.field);
      if (_byKey.containsKey(key)) {
        throw ReplicationManifestException(
          'Duplicate manifest entry for ${entry.entityType}.${entry.field}.',
        );
      }
      _byKey[key] = entry;
      if (entry.isWildcard) {
        _entityDefaults[entry.entityType] = entry;
      }
    }
    _assertNoOrdinaryProfileInsert();
  }

  final int protocolVersion;
  final List<ManifestEntry> _entries;
  final Map<_Key, ManifestEntry> _byKey = <_Key, ManifestEntry>{};
  final Map<String, ManifestEntry> _entityDefaults = <String, ManifestEntry>{};

  /// The special entity boundary for remote profile metadata. It is projected
  /// onto the existing local profile and never inserted/rekeyed as a `profiles`
  /// row (R-SYNC-001, data-model.md §6).
  static const String profileMetadataEntity = 'profile_metadata';

  /// The ordinary local profiles table which must never be replicated.
  static const String ordinaryProfilesEntity = 'profiles';

  List<ManifestEntry> get entries => _entries;

  /// The classification of [entityType].[field] at [protocolVersion].
  ReplicationClass classOf(String entityType, String field) {
    final ManifestEntry? exact = _byKey[_Key(entityType, field)];
    if (exact != null && exact.activeAt(protocolVersion)) {
      return exact.replicationClass;
    }
    final ManifestEntry? wildcard = _entityDefaults[entityType];
    if (wildcard != null && wildcard.activeAt(protocolVersion)) {
      return wildcard.replicationClass;
    }
    // Unknown entity/field: never serialize it.
    return ReplicationClass.localOnly;
  }

  bool isFieldReplicated(String entityType, String field) =>
      classOf(entityType, field) == ReplicationClass.replicated;

  /// True when an entity has any replicated content (its wildcard default is
  /// replicated). Drives outbox eligibility.
  bool isEntityReplicated(String entityType) {
    final ManifestEntry? wildcard = _entityDefaults[entityType];
    return wildcard != null &&
        wildcard.activeAt(protocolVersion) &&
        wildcard.replicationClass == ReplicationClass.replicated;
  }

  /// Projects [fields] to only the replicated subset for [entityType],
  /// dropping local-only and server-only fields before serialization. Exclusion
  /// tests assert local-only fields never survive this projection.
  Map<String, Object?> project(String entityType, Map<String, Object?> fields) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in fields.entries) {
      if (isFieldReplicated(entityType, entry.key)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// The replicated field names present in [fields] for [entityType], sorted
  /// for deterministic wire ordering.
  List<String> replicatedFields(String entityType, Iterable<String> fields) {
    final List<String> replicated = fields
        .where((String field) => isFieldReplicated(entityType, field))
        .toList(growable: false);
    replicated.sort();
    return replicated;
  }

  void _assertNoOrdinaryProfileInsert() {
    final ManifestEntry? profiles = _entityDefaults[ordinaryProfilesEntity];
    if (profiles != null &&
        profiles.replicationClass == ReplicationClass.replicated) {
      throw const ReplicationManifestException(
        'The ordinary profiles table must never be replicated; remote profile '
        'metadata is a projection onto the existing local profile.',
      );
    }
  }
}

final class _Key {
  const _Key(this.entityType, this.field);

  final String entityType;
  final String field;

  @override
  bool operator ==(Object other) =>
      other is _Key && other.entityType == entityType && other.field == field;

  @override
  int get hashCode => Object.hash(entityType, field);
}
