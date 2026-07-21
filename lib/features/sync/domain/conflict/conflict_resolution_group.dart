/// Idempotent conflict-resolution groups (data-model.md §6: "Resolution is a
/// new idempotent group referencing artifact IDs").
///
/// Resolving conflicts is itself a semantic operation, so it is expressed as a
/// group of [ConflictResolutionAction]s that each reference a durable artifact
/// by id and record the chosen outcome. Applying the same group twice yields
/// the same state: an artifact that is already resolved with the same decision
/// is skipped, so there are no duplicate effects. This keeps convergence-ready
/// behavior (task 9.8) without preempting the full convergence property.
library;

import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';

/// One decision within a resolution group: resolve the artifact identified by
/// [remoteArtifactId] with the machine token [resolution].
final class ConflictResolutionAction {
  ConflictResolutionAction({
    required this.remoteArtifactId,
    required this.resolution,
  }) {
    if (remoteArtifactId.isEmpty) {
      throw ArgumentError.value(
        remoteArtifactId,
        'remoteArtifactId',
        'Must not be empty.',
      );
    }
    if (resolution.isEmpty) {
      throw ArgumentError.value(resolution, 'resolution', 'Must not be empty.');
    }
  }

  final String remoteArtifactId;
  final String resolution;
}

/// A group of resolution actions applied atomically and idempotently.
final class ConflictResolutionGroup {
  ConflictResolutionGroup({
    required this.groupId,
    required List<ConflictResolutionAction> actions,
  }) : actions = List<ConflictResolutionAction>.unmodifiable(actions) {
    if (groupId.isEmpty) {
      throw ArgumentError.value(groupId, 'groupId', 'Must not be empty.');
    }
    if (this.actions.isEmpty) {
      throw ArgumentError.value(
        actions,
        'actions',
        'A resolution group must have at least one action.',
      );
    }
    final Set<String> seen = <String>{};
    for (final ConflictResolutionAction action in this.actions) {
      if (!seen.add(action.remoteArtifactId)) {
        throw ArgumentError.value(
          actions,
          'actions',
          'A resolution group must not reference the same artifact twice: '
              '${action.remoteArtifactId}.',
        );
      }
    }
  }

  final String groupId;
  final List<ConflictResolutionAction> actions;
}

/// The result of applying a resolution group to a set of artifacts.
final class ResolutionApplyResult {
  ResolutionApplyResult({
    required Map<String, ConflictArtifact> artifacts,
    required Iterable<String> newlyResolved,
    required Iterable<String> alreadyResolved,
  }) : artifacts = Map<String, ConflictArtifact>.unmodifiable(artifacts),
       newlyResolved = List<String>.unmodifiable(
         newlyResolved.toList(growable: false)..sort(),
       ),
       alreadyResolved = List<String>.unmodifiable(
         alreadyResolved.toList(growable: false)..sort(),
       );

  /// The full artifact set keyed by [ConflictArtifact.remoteArtifactId] after
  /// applying the group.
  final Map<String, ConflictArtifact> artifacts;

  /// Artifacts this application transitioned from open to resolved.
  final List<String> newlyResolved;

  /// Artifacts that were already resolved with the same decision (skipped).
  final List<String> alreadyResolved;
}

/// Applies a resolution group idempotently.
final class ConflictResolutionApplier {
  const ConflictResolutionApplier();

  /// Applies [group] against [current] (keyed by artifact id), resolving each
  /// referenced artifact. Applying the same group again is a no-op on already
  /// resolved artifacts, so `apply(apply(x)) == apply(x)`.
  ///
  /// Throws when the group references an unknown artifact (nothing to resolve)
  /// or when an artifact is already resolved with a *different* decision, which
  /// would be a non-idempotent contradiction rather than a replay.
  ResolutionApplyResult apply({
    required Map<String, ConflictArtifact> current,
    required ConflictResolutionGroup group,
    required int resolvedAtUtc,
  }) {
    final Map<String, ConflictArtifact> next = <String, ConflictArtifact>{
      ...current,
    };
    final List<String> newlyResolved = <String>[];
    final List<String> alreadyResolved = <String>[];

    for (final ConflictResolutionAction action in group.actions) {
      final ConflictArtifact? artifact = next[action.remoteArtifactId];
      if (artifact == null) {
        throw StateError(
          'Resolution group ${group.groupId} references unknown artifact '
          '${action.remoteArtifactId}.',
        );
      }
      if (artifact.isResolved) {
        // Idempotent replay: same decision is a no-op; a different decision is
        // a contradiction that `resolve` rejects.
        artifact.resolve(
          resolution: action.resolution,
          resolvedAtUtc: resolvedAtUtc,
        );
        alreadyResolved.add(action.remoteArtifactId);
        continue;
      }
      next[action.remoteArtifactId] = artifact.resolve(
        resolution: action.resolution,
        resolvedAtUtc: resolvedAtUtc,
      );
      newlyResolved.add(action.remoteArtifactId);
    }

    return ResolutionApplyResult(
      artifacts: next,
      newlyResolved: newlyResolved,
      alreadyResolved: alreadyResolved,
    );
  }
}
