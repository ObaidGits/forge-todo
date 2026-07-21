/// Idempotent conflict-resolution groups (R-SYNC-004, data-model.md §6:
/// "Resolution is a new idempotent group referencing artifact IDs").
///
/// Unit examples plus a named property test asserting `apply(apply(x)) ==
/// apply(x)` — applying the same resolution group twice yields the same state
/// with no duplicate effects.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/conflict/conflict_resolution_group.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-RESOLUTION-GROUP-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.3'),
  requirements: <RequirementId>[RequirementId('R-SYNC-004')],
);

const ConflictResolutionApplier _applier = ConflictResolutionApplier();

ConflictArtifact _openArtifact(String id) => ConflictArtifact(
  remoteArtifactId: id,
  entityType: 'task',
  entityId: 'e-$id',
  policy: ConflictPolicyKind.sameFieldLaterServerWins,
  fields: const <String>['title'],
  createdAtUtc: 1,
  localSnapshot: const <String, Object?>{'title': 'loser'},
  remoteSnapshot: const <String, Object?>{'title': 'winner'},
);

void main() {
  group('ConflictResolutionApplier — examples', () {
    testWithEvidence(
      _evidence('RESOLVES-OPEN-ARTIFACT'),
      'applying a group resolves the referenced open artifact',
      () {
        final Map<String, ConflictArtifact> current =
            <String, ConflictArtifact>{'a1': _openArtifact('a1')};
        final ResolutionApplyResult result = _applier.apply(
          current: current,
          group: ConflictResolutionGroup(
            groupId: 'g1',
            actions: <ConflictResolutionAction>[
              ConflictResolutionAction(
                remoteArtifactId: 'a1',
                resolution: 'keep_remote',
              ),
            ],
          ),
          resolvedAtUtc: 100,
        );
        expect(result.artifacts['a1']!.isResolved, isTrue);
        expect(result.artifacts['a1']!.resolution, 'keep_remote');
        expect(result.artifacts['a1']!.resolvedAtUtc, 100);
        expect(result.newlyResolved, <String>['a1']);
        expect(result.alreadyResolved, isEmpty);
      },
    );

    testWithEvidence(
      _evidence('REPLAY-IS-NOOP'),
      'applying the same group twice resolves once and skips on replay',
      () {
        final ConflictResolutionGroup group = ConflictResolutionGroup(
          groupId: 'g1',
          actions: <ConflictResolutionAction>[
            ConflictResolutionAction(
              remoteArtifactId: 'a1',
              resolution: 'keep_remote',
            ),
          ],
        );
        final ResolutionApplyResult first = _applier.apply(
          current: <String, ConflictArtifact>{'a1': _openArtifact('a1')},
          group: group,
          resolvedAtUtc: 100,
        );
        final ResolutionApplyResult second = _applier.apply(
          current: first.artifacts,
          group: group,
          resolvedAtUtc: 200, // a later replay must not change the state
        );
        expect(second.newlyResolved, isEmpty);
        expect(second.alreadyResolved, <String>['a1']);
        // State is unchanged by the replay: still resolved at the first time.
        expect(second.artifacts['a1']!.resolvedAtUtc, 100);
        expect(second.artifacts['a1'], first.artifacts['a1']);
      },
    );

    testWithEvidence(
      _evidence('UNKNOWN-ARTIFACT-REJECTED'),
      'a group referencing an unknown artifact is rejected',
      () {
        expect(
          () => _applier.apply(
            current: <String, ConflictArtifact>{},
            group: ConflictResolutionGroup(
              groupId: 'g1',
              actions: <ConflictResolutionAction>[
                ConflictResolutionAction(
                  remoteArtifactId: 'missing',
                  resolution: 'x',
                ),
              ],
            ),
            resolvedAtUtc: 1,
          ),
          throwsStateError,
        );
      },
    );

    testWithEvidence(
      _evidence('CONTRADICTORY-REPLAY-REJECTED'),
      'replaying a group with a different decision is rejected as a '
      'contradiction',
      () {
        final ResolutionApplyResult first = _applier.apply(
          current: <String, ConflictArtifact>{'a1': _openArtifact('a1')},
          group: ConflictResolutionGroup(
            groupId: 'g1',
            actions: <ConflictResolutionAction>[
              ConflictResolutionAction(
                remoteArtifactId: 'a1',
                resolution: 'keep_remote',
              ),
            ],
          ),
          resolvedAtUtc: 1,
        );
        expect(
          () => _applier.apply(
            current: first.artifacts,
            group: ConflictResolutionGroup(
              groupId: 'g1',
              actions: <ConflictResolutionAction>[
                ConflictResolutionAction(
                  remoteArtifactId: 'a1',
                  resolution: 'keep_local',
                ),
              ],
            ),
            resolvedAtUtc: 2,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('ConflictResolutionApplier — properties', () {
    testWithEvidence(
      _evidence('PROP-IDEMPOTENT'),
      'apply(apply(x)) == apply(x): a replayed resolution group yields the '
      'same state with no duplicate effects',
      () {
        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);
          final int artifactCount = 1 + rng.nextInt(6);
          final Map<String, ConflictArtifact> current =
              <String, ConflictArtifact>{
                for (int i = 0; i < artifactCount; i += 1)
                  'a$i': _openArtifact('a$i'),
              };

          // A group referencing a random non-empty subset of the artifacts.
          final List<String> ids = current.keys.toList()..shuffle(rng);
          final int chosen = 1 + rng.nextInt(ids.length);
          final List<ConflictResolutionAction> actions =
              <ConflictResolutionAction>[
                for (final String id in ids.take(chosen))
                  ConflictResolutionAction(
                    remoteArtifactId: id,
                    resolution: 'decision-${rng.nextInt(3)}',
                  ),
              ];
          final ConflictResolutionGroup group = ConflictResolutionGroup(
            groupId: 'g$seed',
            actions: actions,
          );

          final ResolutionApplyResult once = _applier.apply(
            current: current,
            group: group,
            resolvedAtUtc: 100,
          );
          final ResolutionApplyResult twice = _applier.apply(
            current: once.artifacts,
            group: group,
            resolvedAtUtc: 999, // replay at a different time
          );

          // Idempotence: the artifact set is identical after a replay.
          expect(
            twice.artifacts.length,
            once.artifacts.length,
            reason: 'seed=$seed',
          );
          for (final String id in once.artifacts.keys) {
            expect(
              twice.artifacts[id],
              once.artifacts[id],
              reason: 'state diverged for $id seed=$seed',
            );
          }
          // The replay performs no new resolutions.
          expect(twice.newlyResolved, isEmpty, reason: 'seed=$seed');
          expect(twice.alreadyResolved.length, chosen, reason: 'seed=$seed');
        }
      },
    );
  });
}
