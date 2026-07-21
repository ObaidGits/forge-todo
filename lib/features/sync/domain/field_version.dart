/// Per-field version metadata sufficient for disjoint-field merge (R-SYNC-004,
/// data-model.md §6).
///
/// Server rows maintain, per field, a `(version, last_operation_id)` pair.
/// Concurrent disjoint-field edits merge by taking each side's fields; a
/// same-field conflict is resolved by later server acceptance while preserving
/// the losing value in a durable conflict artifact (handled by task 9.3). These
/// pure helpers implement the deterministic version arithmetic the client uses
/// to build patch bases and detect same-field contention.
library;

/// The `(version, lastOperationId)` metadata for one field.
final class FieldVersion implements Comparable<FieldVersion> {
  FieldVersion({required this.version, required this.lastOperationId}) {
    if (version < 0) {
      throw ArgumentError.value(version, 'version', 'Must be nonnegative.');
    }
  }

  final int version;
  final String lastOperationId;

  @override
  int compareTo(FieldVersion other) => version.compareTo(other.version);

  @override
  bool operator ==(Object other) =>
      other is FieldVersion &&
      other.version == version &&
      other.lastOperationId == lastOperationId;

  @override
  int get hashCode => Object.hash(version, lastOperationId);

  @override
  String toString() => 'FieldVersion($version, $lastOperationId)';
}

/// An immutable map of field name to [FieldVersion].
final class FieldVersionMap {
  FieldVersionMap(Map<String, FieldVersion> versions)
    : _versions = Map<String, FieldVersion>.unmodifiable(versions);

  factory FieldVersionMap.empty() =>
      FieldVersionMap(const <String, FieldVersion>{});

  final Map<String, FieldVersion> _versions;

  Map<String, FieldVersion> get versions => _versions;

  FieldVersion? operator [](String field) => _versions[field];

  Iterable<String> get fields => _versions.keys;

  bool get isEmpty => _versions.isEmpty;

  /// True when [base] and [incoming] change no field in common — the condition
  /// under which concurrent edits merge cleanly (R-SYNC-004 disjoint merge).
  static bool disjoint(Iterable<String> a, Iterable<String> b) {
    final Set<String> left = a.toSet();
    for (final String field in b) {
      if (left.contains(field)) {
        return false;
      }
    }
    return true;
  }

  /// Merges two disjoint-field version maps. Throws when they share a field,
  /// because a shared field is a same-field contention that must go through the
  /// conflict policy rather than a silent merge.
  FieldVersionMap mergeDisjoint(FieldVersionMap other) {
    final Map<String, FieldVersion> merged = <String, FieldVersion>{
      ..._versions,
    };
    for (final MapEntry<String, FieldVersion> entry
        in other._versions.entries) {
      if (merged.containsKey(entry.key)) {
        throw StateError(
          'Cannot disjoint-merge overlapping field: ${entry.key}.',
        );
      }
      merged[entry.key] = entry.value;
    }
    return FieldVersionMap(merged);
  }

  /// The fields whose base version is older than the server's current version —
  /// i.e. the fields the server has since changed. An empty result means the
  /// patch's base is current and the patch may be accepted (conflict policy
  /// rule 2).
  List<String> staleFields(FieldVersionMap serverVersions) {
    final List<String> stale = <String>[];
    for (final MapEntry<String, FieldVersion> entry in _versions.entries) {
      final FieldVersion? server = serverVersions[entry.key];
      if (server != null && server.version > entry.value.version) {
        stale.add(entry.key);
      }
    }
    stale.sort();
    return stale;
  }

  /// Compacts a chronological list of per-field version observations into the
  /// latest version per field (field-version compaction, testing.md §4/§8).
  /// Later observations for the same field supersede earlier ones; ordering is
  /// by the observation list, not by numeric version, so the caller controls
  /// authority order (server acceptance order).
  static FieldVersionMap compact(Iterable<FieldVersionMap> observations) {
    final Map<String, FieldVersion> latest = <String, FieldVersion>{};
    for (final FieldVersionMap observation in observations) {
      latest.addAll(observation._versions);
    }
    return FieldVersionMap(latest);
  }
}
