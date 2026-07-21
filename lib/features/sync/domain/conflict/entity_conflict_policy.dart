/// Typed, deterministic entity conflict policies (R-SYNC-004, data-model.md §6
/// "Conflict policy" rules 3, 4, and 8).
///
/// These pure policies decide the converged state of one entity when a pulled
/// server change collides with a pending local edit, and — crucially — they
/// never silently lose a meaningful value. Concurrent edits to *disjoint*
/// fields merge (rule 3). Concurrent edits to the *same* scalar field resolve
/// by later server acceptance while preserving the losing local value in a
/// durable [ConflictArtifact] (rule 4). A delete concurrent with an update
/// keeps the tombstone as the visible state while preserving the update
/// (rule 8): no silent resurrection, no silent loss.
///
/// The engine is intentionally generic over the per-field contracts from task
/// 9.1 ([FieldVersionMap]) so it stays pure and testable; feature appliers map
/// its decisions onto their own rows and, for notes, defer body reconciliation
/// to [mergeNoteBody].
library;

import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/field_version.dart';

/// One side's edit to an entity: the fields it changed relative to the shared
/// base and the values it set.
final class EntityEdit {
  EntityEdit({
    required Iterable<String> changedFields,
    required Map<String, Object?> values,
  }) : changedFields = Set<String>.unmodifiable(changedFields),
       values = Map<String, Object?>.unmodifiable(values) {
    for (final String field in this.changedFields) {
      if (!this.values.containsKey(field)) {
        throw ArgumentError.value(
          field,
          'changedFields',
          'Every changed field must have a value in `values`.',
        );
      }
    }
  }

  /// An edit that changed nothing.
  factory EntityEdit.none() => EntityEdit(
    changedFields: const <String>[],
    values: const <String, Object?>{},
  );

  final Set<String> changedFields;
  final Map<String, Object?> values;

  bool get isEmpty => changedFields.isEmpty;
}

/// The outcome of resolving one entity's scalar-field contention.
final class FieldMergeResult {
  FieldMergeResult({
    required Map<String, Object?> mergedValues,
    required Iterable<String> mergedFromLocal,
    required Iterable<String> mergedFromRemote,
    required Iterable<String> contendedFields,
    this.artifact,
  }) : mergedValues = Map<String, Object?>.unmodifiable(mergedValues),
       mergedFromLocal = List<String>.unmodifiable(
         mergedFromLocal.toList(growable: false)..sort(),
       ),
       mergedFromRemote = List<String>.unmodifiable(
         mergedFromRemote.toList(growable: false)..sort(),
       ),
       contendedFields = List<String>.unmodifiable(
         contendedFields.toList(growable: false)..sort(),
       );

  /// The converged value per field the resolution touched.
  final Map<String, Object?> mergedValues;

  /// The fields whose converged value came from the local side (disjoint local
  /// edits that survived).
  final List<String> mergedFromLocal;

  /// The fields whose converged value came from the server side (disjoint
  /// remote edits, plus every contended field where the server won).
  final List<String> mergedFromRemote;

  /// The fields edited on both sides (same-field contention). Empty when the
  /// edits were fully disjoint.
  final List<String> contendedFields;

  /// The durable artifact preserving the losing local values, when there was
  /// any same-field contention. Null for a clean disjoint merge.
  final ConflictArtifact? artifact;

  bool get hadContention => contendedFields.isNotEmpty;
}

/// The outcome of a delete-versus-update collision (rule 8).
final class TombstoneMergeResult {
  const TombstoneMergeResult({required this.tombstoneWins, this.artifact});

  /// True when the entity's visible state is the tombstone (deleted). Under
  /// rule 8 a tombstone always wins visible state against a concurrent update.
  final bool tombstoneWins;

  /// The durable artifact preserving the concurrent update so it survives in
  /// trash/conflict. Null when there was no update to preserve (delete vs
  /// delete).
  final ConflictArtifact? artifact;
}

/// Pure, deterministic conflict resolution for one entity.
final class EntityConflictPolicy {
  const EntityConflictPolicy();

  /// Resolves concurrent scalar-field edits.
  ///
  /// [baseValues] are the values both sides started from. [local] and [remote]
  /// are the two concurrent edits; [remote] is the server-accepted side.
  /// [remoteVersions] carries the server's per-field versions so the artifact
  /// records the winning version metadata.
  ///
  /// Disjoint fields merge (each side keeps its own). A field edited on both
  /// sides is *contended*: the server value wins the converged state (later
  /// server acceptance) and the losing local value is preserved in the returned
  /// [ConflictArtifact], stamped [artifactId].
  FieldMergeResult resolveFields({
    required String entityType,
    required String entityId,
    required EntityEdit local,
    required EntityEdit remote,
    required Map<String, Object?> baseValues,
    required int createdAtUtc,
    String? artifactId,
    FieldVersionMap? remoteVersions,
    int? retainedUntilUtc,
  }) {
    final Set<String> contended = <String>{};
    for (final String field in local.changedFields) {
      if (remote.changedFields.contains(field)) {
        contended.add(field);
      }
    }

    final Map<String, Object?> merged = <String, Object?>{};
    final Set<String> fromLocal = <String>{};
    final Set<String> fromRemote = <String>{};

    // Remote (server-accepted) edits: win every field they touched, including
    // contended ones (later server acceptance wins).
    for (final String field in remote.changedFields) {
      merged[field] = remote.values[field];
      fromRemote.add(field);
    }
    // Disjoint local edits survive.
    for (final String field in local.changedFields) {
      if (!contended.contains(field)) {
        merged[field] = local.values[field];
        fromLocal.add(field);
      }
    }

    ConflictArtifact? artifact;
    if (contended.isNotEmpty) {
      if (artifactId == null) {
        throw ArgumentError.value(
          artifactId,
          'artifactId',
          'A same-field contention must be recorded in a durable artifact; '
              'provide an artifactId.',
        );
      }
      final List<String> sortedContended = contended.toList()..sort();
      artifact = ConflictArtifact(
        remoteArtifactId: artifactId,
        entityType: entityType,
        entityId: entityId,
        policy: ConflictPolicyKind.sameFieldLaterServerWins,
        fields: sortedContended,
        createdAtUtc: createdAtUtc,
        retainedUntilUtc: retainedUntilUtc,
        baseSnapshot: <String, Object?>{
          for (final String field in sortedContended) field: baseValues[field],
        },
        localSnapshot: <String, Object?>{
          for (final String field in sortedContended)
            field: local.values[field],
        },
        remoteSnapshot: <String, Object?>{
          for (final String field in sortedContended)
            field: remote.values[field],
        },
      );
    }

    return FieldMergeResult(
      mergedValues: merged,
      mergedFromLocal: fromLocal,
      mergedFromRemote: fromRemote,
      contendedFields: contended,
      artifact: artifact,
    );
  }

  /// Resolves a delete concurrent with an update (rule 8).
  ///
  /// The tombstone always wins the visible state. When the opposite side made a
  /// meaningful update, that update is preserved in a durable artifact so it
  /// survives in trash/conflict — never silently resurrected into the visible
  /// entity, never silently lost.
  TombstoneMergeResult resolveDeleteVersusUpdate({
    required String entityType,
    required String entityId,
    required EntityEdit survivingUpdate,
    required Map<String, Object?> baseValues,
    required int createdAtUtc,
    String? artifactId,
    int? retainedUntilUtc,
  }) {
    if (survivingUpdate.isEmpty) {
      // Delete versus delete (or delete versus no-op): tombstone wins, nothing
      // meaningful to preserve.
      return const TombstoneMergeResult(tombstoneWins: true);
    }
    if (artifactId == null) {
      throw ArgumentError.value(
        artifactId,
        'artifactId',
        'A preserved update must be recorded in a durable artifact; provide an '
            'artifactId.',
      );
    }
    final List<String> updatedFields = survivingUpdate.changedFields.toList()
      ..sort();
    final ConflictArtifact artifact = ConflictArtifact(
      remoteArtifactId: artifactId,
      entityType: entityType,
      entityId: entityId,
      policy: ConflictPolicyKind.tombstoneUpdatePreserved,
      fields: updatedFields,
      createdAtUtc: createdAtUtc,
      retainedUntilUtc: retainedUntilUtc,
      baseSnapshot: <String, Object?>{
        for (final String field in updatedFields) field: baseValues[field],
      },
      localSnapshot: <String, Object?>{
        for (final String field in updatedFields)
          field: survivingUpdate.values[field],
      },
    );
    return TombstoneMergeResult(tombstoneWins: true, artifact: artifact);
  }
}
