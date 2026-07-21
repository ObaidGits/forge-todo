/// One command's ordered remote operations, accepted or rejected as a unit
/// (glossary "Semantic transaction group"; R-SYNC-003, R-SYNC-004).
///
/// A group's operations carry contiguous 0-based indices and are ordered
/// parent-before-child; unresolved references may be deferred only within the
/// same group and reject the group if unresolved at commit. The whole group is
/// fully accepted or fully rejected.
library;

import 'package:forge/features/sync/domain/field_version.dart';

/// The kind of a single wire operation.
enum SyncOperationKind {
  insert,
  patch,
  delete;

  static SyncOperationKind fromWire(String value) => switch (value) {
    'insert' => SyncOperationKind.insert,
    'patch' => SyncOperationKind.patch,
    'delete' => SyncOperationKind.delete,
    _ => throw ArgumentError.value(value, 'value', 'Unknown operation kind'),
  };

  String get wire => name;
}

/// A single ordered operation within a semantic group.
final class SyncOperation {
  SyncOperation({
    required this.operationId,
    required this.index,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.payload,
    this.parentEntityId,
    this.baseRowVersion,
    this.baseFieldVersions,
    this.changedFields = const <String>[],
    this.clientRevision,
  }) {
    if (index < 0) {
      throw ArgumentError.value(index, 'index', 'Must be nonnegative.');
    }
    if (kind == SyncOperationKind.patch && changedFields.isEmpty) {
      throw ArgumentError.value(
        changedFields,
        'changedFields',
        'A patch must change at least one field.',
      );
    }
  }

  final String operationId;
  final int index;
  final String entityType;
  final String entityId;
  final SyncOperationKind kind;

  /// The already-serialized, manifest-projected payload for this operation.
  final Map<String, Object?> payload;

  /// The strict-parent entity ID this operation depends on, when any. Used to
  /// validate parent-before-child ordering within the group.
  final String? parentEntityId;

  final int? baseRowVersion;
  final FieldVersionMap? baseFieldVersions;
  final List<String> changedFields;
  final int? clientRevision;
}

/// Raised when a group violates its structural invariants.
final class SemanticGroupException implements Exception {
  const SemanticGroupException(this.reason);

  final String reason;

  @override
  String toString() => 'SemanticGroupException: $reason';
}

/// An ordered, all-or-reject semantic group bound to one snapshot epoch.
final class SemanticGroup {
  SemanticGroup({
    required this.groupId,
    required this.snapshotEpoch,
    required List<SyncOperation> operations,
  }) : operations = List<SyncOperation>.unmodifiable(operations) {
    if (this.operations.isEmpty) {
      throw const SemanticGroupException('A group must have operations.');
    }
    _assertContiguousIndices();
    _assertParentBeforeChild();
  }

  final String groupId;
  final int snapshotEpoch;
  final List<SyncOperation> operations;

  int get operationCount => operations.length;

  void _assertContiguousIndices() {
    for (int i = 0; i < operations.length; i += 1) {
      if (operations[i].index != i) {
        throw SemanticGroupException(
          'Operation indices must be contiguous 0..n-1; expected $i but found '
          '${operations[i].index}.',
        );
      }
    }
  }

  void _assertParentBeforeChild() {
    final Set<String> seen = <String>{};
    for (final SyncOperation op in operations) {
      final String? parent = op.parentEntityId;
      if (parent != null &&
          parent != op.entityId &&
          !seen.contains(parent) &&
          _parentInGroup(parent)) {
        throw SemanticGroupException(
          'Child ${op.entityId} precedes its parent $parent within the group.',
        );
      }
      seen.add(op.entityId);
    }
  }

  bool _parentInGroup(String parentEntityId) =>
      operations.any((SyncOperation op) => op.entityId == parentEntityId);
}

/// The per-group acceptance outcome returned by push. Independent groups may
/// have explicit results; the client acknowledges only committed groups
/// (R-SYNC-003, data-model.md §6).
enum SemanticGroupOutcome { accepted, rejected, conflict, staleEpoch }

/// The result of pushing one semantic group.
final class SemanticGroupResult {
  const SemanticGroupResult({
    required this.groupId,
    required this.outcome,
    this.conflictArtifactId,
    this.rejectionReason,
  });

  final String groupId;
  final SemanticGroupOutcome outcome;
  final String? conflictArtifactId;
  final String? rejectionReason;

  bool get isAcknowledgeable =>
      outcome == SemanticGroupOutcome.accepted ||
      outcome == SemanticGroupOutcome.conflict;
}
