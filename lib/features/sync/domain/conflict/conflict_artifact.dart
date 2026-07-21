/// A durable, pullable conflict artifact preserving every meaningful losing
/// value (R-SYNC-004, R-NOTE-007, data-model.md §6 "Conflict policy").
///
/// When a same-field contention, a note that cannot be exact-base merged, or a
/// delete-versus-update collision is resolved, the *losing* value is never
/// silently dropped: it is captured in a [ConflictArtifact] that persists via
/// the `sync_conflicts` table until it is explicitly resolved plus its
/// retention window expires. Artifacts are ordinary durable pull records, so a
/// losing value can always be recovered on any device.
///
/// This value object is pure: it has no Drift/Flutter imports and carries only
/// the immutable snapshot data the policy engine and the durable store share.
library;

/// The deterministic rule that produced an artifact. The spelling mirrors the
/// numbered rules in data-model.md §6 so evidence and the durable `policy`
/// column read the same on every device.
enum ConflictPolicyKind {
  /// Rule 4: a same scalar field edited on both sides. Later server acceptance
  /// wins the visible value; the losing value is preserved here.
  sameFieldLaterServerWins,

  /// Rule 5: a note body that could not be exact-base three-way merged, so both
  /// bodies survive (the current body plus a conflict-copy note).
  noteConflictCopy,

  /// Rule 8: a delete concurrent with an update. The tombstone wins visible
  /// state; the concurrent update survives here (in trash/conflict).
  tombstoneUpdatePreserved;

  /// The wire/column spelling.
  String get wire => switch (this) {
    ConflictPolicyKind.sameFieldLaterServerWins =>
      'same_field_later_server_wins',
    ConflictPolicyKind.noteConflictCopy => 'note_conflict_copy',
    ConflictPolicyKind.tombstoneUpdatePreserved => 'tombstone_update_preserved',
  };

  /// Parses a column/wire spelling, rejecting unknown values so a corrupt or
  /// forged row cannot be silently misread.
  static ConflictPolicyKind fromWire(String value) => switch (value) {
    'same_field_later_server_wins' =>
      ConflictPolicyKind.sameFieldLaterServerWins,
    'note_conflict_copy' => ConflictPolicyKind.noteConflictCopy,
    'tombstone_update_preserved' => ConflictPolicyKind.tombstoneUpdatePreserved,
    _ => throw ArgumentError.value(value, 'value', 'Unknown conflict policy'),
  };
}

/// The lifecycle status of an artifact. Matches the `sync_conflicts.status`
/// CHECK constraint (`open`/`resolved`).
enum ConflictStatus {
  open,
  resolved;

  String get wire => name;

  static ConflictStatus fromWire(String value) => switch (value) {
    'open' => ConflictStatus.open,
    'resolved' => ConflictStatus.resolved,
    _ => throw ArgumentError.value(value, 'value', 'Unknown conflict status'),
  };
}

/// One durable conflict artifact. It is uniquely identified by its
/// [remoteArtifactId]; the same artifact pulled twice is the same record.
final class ConflictArtifact {
  ConflictArtifact({
    required this.remoteArtifactId,
    required this.entityType,
    required this.entityId,
    required this.policy,
    required Iterable<String> fields,
    required this.createdAtUtc,
    this.baseSnapshot,
    this.localSnapshot,
    this.remoteSnapshot,
    this.status = ConflictStatus.open,
    this.resolution,
    this.retainedUntilUtc,
    this.resolvedAtUtc,
  }) : fields = List<String>.unmodifiable(
         fields.toList(growable: false)..sort(),
       ) {
    if (remoteArtifactId.isEmpty) {
      throw ArgumentError.value(
        remoteArtifactId,
        'remoteArtifactId',
        'Must not be empty.',
      );
    }
    if (entityType.isEmpty) {
      throw ArgumentError.value(entityType, 'entityType', 'Must not be empty.');
    }
    if (status == ConflictStatus.resolved && resolvedAtUtc == null) {
      throw ArgumentError.value(
        resolvedAtUtc,
        'resolvedAtUtc',
        'A resolved artifact must record when it was resolved.',
      );
    }
  }

  /// The server-assigned durable artifact ID. Stable across pulls and devices.
  final String remoteArtifactId;

  final String entityType;
  final String entityId;

  final ConflictPolicyKind policy;

  /// The sorted set of contended fields (for a note body this is `['body']`).
  final List<String> fields;

  /// The exact base value(s) where available; a hash alone is insufficient for
  /// a note merge (R-NOTE-007), so the base snapshot carries the actual value.
  final Map<String, Object?>? baseSnapshot;

  /// The losing local value(s) preserved so they can always be recovered.
  final Map<String, Object?>? localSnapshot;

  /// The server-accepted (winning) value(s) at the time the artifact was made.
  final Map<String, Object?>? remoteSnapshot;

  final ConflictStatus status;

  /// A short machine token describing how the artifact was resolved, when it
  /// has been. Null while [status] is [ConflictStatus.open].
  final String? resolution;

  final int? retainedUntilUtc;
  final int createdAtUtc;
  final int? resolvedAtUtc;

  bool get isOpen => status == ConflictStatus.open;
  bool get isResolved => status == ConflictStatus.resolved;

  /// Returns a resolved copy. Resolving an already-resolved artifact with the
  /// same [resolution] is a no-op returning `this`, so resolution is
  /// idempotent (data-model.md §6 "Resolution is a new idempotent group").
  ConflictArtifact resolve({
    required String resolution,
    required int resolvedAtUtc,
  }) {
    if (isResolved) {
      if (this.resolution == resolution) {
        return this;
      }
      throw StateError(
        'Artifact $remoteArtifactId is already resolved as ${this.resolution}; '
        'cannot re-resolve as $resolution.',
      );
    }
    return ConflictArtifact(
      remoteArtifactId: remoteArtifactId,
      entityType: entityType,
      entityId: entityId,
      policy: policy,
      fields: fields,
      createdAtUtc: createdAtUtc,
      baseSnapshot: baseSnapshot,
      localSnapshot: localSnapshot,
      remoteSnapshot: remoteSnapshot,
      status: ConflictStatus.resolved,
      resolution: resolution,
      retainedUntilUtc: retainedUntilUtc,
      resolvedAtUtc: resolvedAtUtc,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ConflictArtifact &&
      other.remoteArtifactId == remoteArtifactId &&
      other.entityType == entityType &&
      other.entityId == entityId &&
      other.policy == policy &&
      _listEquals(other.fields, fields) &&
      _mapEquals(other.baseSnapshot, baseSnapshot) &&
      _mapEquals(other.localSnapshot, localSnapshot) &&
      _mapEquals(other.remoteSnapshot, remoteSnapshot) &&
      other.status == status &&
      other.resolution == resolution &&
      other.retainedUntilUtc == retainedUntilUtc &&
      other.createdAtUtc == createdAtUtc &&
      other.resolvedAtUtc == resolvedAtUtc;

  @override
  int get hashCode => Object.hash(
    remoteArtifactId,
    entityType,
    entityId,
    policy,
    Object.hashAll(fields),
    status,
    resolution,
    retainedUntilUtc,
    createdAtUtc,
    resolvedAtUtc,
  );

  @override
  String toString() =>
      'ConflictArtifact($remoteArtifactId, $entityType/$entityId, '
      '${policy.wire}, ${status.wire}, fields=$fields)';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _mapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final MapEntry<String, Object?> entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
