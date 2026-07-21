/// Typed entity conflict policies: disjoint-field merge, same-field
/// contention preserving the loser, and delete-versus-update preservation
/// (R-SYNC-004, data-model.md §6 rules 3/4/8).
///
/// Unit examples plus three named property tests:
///  * disjoint merge commutativity;
///  * same-field conflict preserves the losing value in a durable artifact;
///  * tombstone/update preservation (no silent resurrection, no silent loss).
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/conflict/entity_conflict_policy.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-CONFLICT-POLICY-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.3'),
  requirements: <RequirementId>[RequirementId('R-SYNC-004')],
);

const EntityConflictPolicy _policy = EntityConflictPolicy();

void main() {
  group('EntityConflictPolicy.resolveFields — examples', () {
    testWithEvidence(
      _evidence('DISJOINT-MERGES-BOTH-SIDES'),
      'disjoint-field edits merge without a conflict artifact',
      () {
        final FieldMergeResult result = _policy.resolveFields(
          entityType: 'task',
          entityId: 'e1',
          local: EntityEdit(
            changedFields: const <String>['title'],
            values: const <String, Object?>{'title': 'local title'},
          ),
          remote: EntityEdit(
            changedFields: const <String>['notes'],
            values: const <String, Object?>{'notes': 'remote notes'},
          ),
          baseValues: const <String, Object?>{'title': 'base', 'notes': 'base'},
          createdAtUtc: 10,
        );

        expect(result.hadContention, isFalse);
        expect(result.artifact, isNull);
        expect(result.mergedValues['title'], 'local title');
        expect(result.mergedValues['notes'], 'remote notes');
        expect(result.mergedFromLocal, <String>['title']);
        expect(result.mergedFromRemote, <String>['notes']);
      },
    );

    testWithEvidence(
      _evidence('SAME-FIELD-SERVER-WINS-PRESERVES-LOSER'),
      'a same-field edit resolves to the server value and preserves the loser',
      () {
        final FieldMergeResult result = _policy.resolveFields(
          entityType: 'task',
          entityId: 'e1',
          local: EntityEdit(
            changedFields: const <String>['title'],
            values: const <String, Object?>{'title': 'local wins?'},
          ),
          remote: EntityEdit(
            changedFields: const <String>['title'],
            values: const <String, Object?>{'title': 'server accepted'},
          ),
          baseValues: const <String, Object?>{'title': 'base'},
          createdAtUtc: 42,
          artifactId: 'artifact-1',
        );

        expect(result.hadContention, isTrue);
        expect(result.contendedFields, <String>['title']);
        // Later server acceptance wins the visible value.
        expect(result.mergedValues['title'], 'server accepted');
        // The losing local value is preserved durably.
        final ConflictArtifact artifact = result.artifact!;
        expect(artifact.policy, ConflictPolicyKind.sameFieldLaterServerWins);
        expect(artifact.localSnapshot!['title'], 'local wins?');
        expect(artifact.remoteSnapshot!['title'], 'server accepted');
        expect(artifact.baseSnapshot!['title'], 'base');
        expect(artifact.isOpen, isTrue);
      },
    );

    testWithEvidence(
      _evidence('SAME-FIELD-REQUIRES-ARTIFACT-ID'),
      'a same-field contention without an artifact id is rejected',
      () {
        expect(
          () => _policy.resolveFields(
            entityType: 'task',
            entityId: 'e1',
            local: EntityEdit(
              changedFields: const <String>['title'],
              values: const <String, Object?>{'title': 'a'},
            ),
            remote: EntityEdit(
              changedFields: const <String>['title'],
              values: const <String, Object?>{'title': 'b'},
            ),
            baseValues: const <String, Object?>{'title': 'base'},
            createdAtUtc: 1,
          ),
          throwsArgumentError,
        );
      },
    );

    testWithEvidence(
      _evidence('MIXED-DISJOINT-AND-CONTENDED'),
      'disjoint fields merge while only the shared field is contended',
      () {
        final FieldMergeResult result = _policy.resolveFields(
          entityType: 'task',
          entityId: 'e1',
          local: EntityEdit(
            changedFields: const <String>['title', 'priority'],
            values: const <String, Object?>{'title': 'lt', 'priority': 3},
          ),
          remote: EntityEdit(
            changedFields: const <String>['title', 'notes'],
            values: const <String, Object?>{'title': 'rt', 'notes': 'rn'},
          ),
          baseValues: const <String, Object?>{
            'title': 'base',
            'priority': 0,
            'notes': '',
          },
          createdAtUtc: 5,
          artifactId: 'artifact-2',
        );

        expect(result.contendedFields, <String>['title']);
        expect(result.mergedValues['title'], 'rt'); // server wins the overlap
        expect(result.mergedValues['priority'], 3); // disjoint local survives
        expect(result.mergedValues['notes'], 'rn'); // disjoint remote survives
        expect(result.artifact!.fields, <String>['title']);
      },
    );
  });

  group('EntityConflictPolicy.resolveDeleteVersusUpdate — examples', () {
    testWithEvidence(
      _evidence('DELETE-VS-UPDATE-TOMBSTONE-WINS'),
      'a delete concurrent with an update keeps the tombstone and preserves '
      'the update',
      () {
        final TombstoneMergeResult result = _policy.resolveDeleteVersusUpdate(
          entityType: 'task',
          entityId: 'e1',
          survivingUpdate: EntityEdit(
            changedFields: const <String>['title'],
            values: const <String, Object?>{'title': 'edited concurrently'},
          ),
          baseValues: const <String, Object?>{'title': 'base'},
          createdAtUtc: 7,
          artifactId: 'artifact-3',
        );

        expect(result.tombstoneWins, isTrue);
        expect(result.artifact, isNotNull);
        expect(
          result.artifact!.policy,
          ConflictPolicyKind.tombstoneUpdatePreserved,
        );
        expect(result.artifact!.localSnapshot!['title'], 'edited concurrently');
      },
    );

    testWithEvidence(
      _evidence('DELETE-VS-DELETE-NO-ARTIFACT'),
      'a delete with no concurrent update needs no artifact',
      () {
        final TombstoneMergeResult result = _policy.resolveDeleteVersusUpdate(
          entityType: 'task',
          entityId: 'e1',
          survivingUpdate: EntityEdit.none(),
          baseValues: const <String, Object?>{},
          createdAtUtc: 7,
        );

        expect(result.tombstoneWins, isTrue);
        expect(result.artifact, isNull);
      },
    );
  });

  group('EntityConflictPolicy — properties', () {
    testWithEvidence(
      _evidence('PROP-DISJOINT-MERGE-COMMUTATIVE'),
      'disjoint-field merge is commutative: swapping local and remote yields '
      'the same converged fields',
      () {
        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);
          final _DisjointCase c = _randomDisjointCase(rng);

          final FieldMergeResult ab = _policy.resolveFields(
            entityType: 'task',
            entityId: 'e1',
            local: c.left,
            remote: c.right,
            baseValues: c.baseValues,
            createdAtUtc: 1,
          );
          final FieldMergeResult ba = _policy.resolveFields(
            entityType: 'task',
            entityId: 'e1',
            local: c.right,
            remote: c.left,
            baseValues: c.baseValues,
            createdAtUtc: 1,
          );

          // Disjoint edits never contend and never create an artifact.
          expect(ab.hadContention, isFalse, reason: 'seed=$seed');
          expect(ba.hadContention, isFalse, reason: 'seed=$seed');
          expect(ab.artifact, isNull, reason: 'seed=$seed');
          expect(ba.artifact, isNull, reason: 'seed=$seed');

          // The converged value map is identical regardless of side order.
          expect(
            ab.mergedValues,
            equals(ba.mergedValues),
            reason: 'non-commutative for seed=$seed',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-SAME-FIELD-PRESERVES-LOSER'),
      'every contended field preserves its losing local value while the server '
      'value wins the converged state',
      () {
        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);
          final _OverlapCase c = _randomOverlapCase(rng);

          final FieldMergeResult result = _policy.resolveFields(
            entityType: 'note',
            entityId: 'e1',
            local: c.local,
            remote: c.remote,
            baseValues: c.baseValues,
            createdAtUtc: 1,
            artifactId: 'artifact-$seed',
          );

          expect(result.hadContention, isTrue, reason: 'seed=$seed');
          final ConflictArtifact artifact = result.artifact!;
          for (final String field in result.contendedFields) {
            // Server value wins the converged state.
            expect(
              result.mergedValues[field],
              c.remote.values[field],
              reason: 'server did not win $field for seed=$seed',
            );
            // Losing local value is recoverable from the artifact.
            expect(
              artifact.localSnapshot![field],
              c.local.values[field],
              reason: 'loser lost for $field seed=$seed',
            );
            expect(
              artifact.remoteSnapshot![field],
              c.remote.values[field],
              reason: 'winner missing for $field seed=$seed',
            );
          }
          expect(
            artifact.policy,
            ConflictPolicyKind.sameFieldLaterServerWins,
            reason: 'seed=$seed',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-TOMBSTONE-UPDATE-PRESERVED'),
      'a delete-versus-update always tombstones the visible state and never '
      'silently loses the concurrent update',
      () {
        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);
          final EntityEdit update = _randomEdit(rng, <String>[
            'title',
            'body',
            'priority',
          ]);

          final TombstoneMergeResult result = _policy.resolveDeleteVersusUpdate(
            entityType: 'task',
            entityId: 'e1',
            survivingUpdate: update,
            baseValues: const <String, Object?>{
              'title': 'b',
              'body': 'b',
              'priority': 0,
            },
            createdAtUtc: 1,
            artifactId: update.isEmpty ? null : 'artifact-$seed',
          );

          // Tombstone always wins the visible state: no silent resurrection.
          expect(result.tombstoneWins, isTrue, reason: 'seed=$seed');

          if (update.isEmpty) {
            expect(result.artifact, isNull, reason: 'seed=$seed');
          } else {
            // The concurrent update is preserved: no silent loss.
            final ConflictArtifact artifact = result.artifact!;
            expect(
              artifact.policy,
              ConflictPolicyKind.tombstoneUpdatePreserved,
              reason: 'seed=$seed',
            );
            for (final String field in update.changedFields) {
              expect(
                artifact.localSnapshot![field],
                update.values[field],
                reason: 'update lost for $field seed=$seed',
              );
            }
          }
        }
      },
    );
  });
}

final class _DisjointCase {
  _DisjointCase({
    required this.left,
    required this.right,
    required this.baseValues,
  });

  final EntityEdit left;
  final EntityEdit right;
  final Map<String, Object?> baseValues;
}

final class _OverlapCase {
  _OverlapCase({
    required this.local,
    required this.remote,
    required this.baseValues,
  });

  final EntityEdit local;
  final EntityEdit remote;
  final Map<String, Object?> baseValues;
}

const List<String> _fieldPool = <String>[
  'title',
  'body',
  'priority',
  'notes',
  'tag',
  'rank',
];

Map<String, Object?> _baseFor(Iterable<String> fields) => <String, Object?>{
  for (final String field in fields) field: 'base:$field',
};

_DisjointCase _randomDisjointCase(Random rng) {
  final List<String> shuffled = List<String>.of(_fieldPool)..shuffle(rng);
  final int leftCount = rng.nextInt(3); // 0..2
  final int rightCount = rng.nextInt(3);
  final List<String> leftFields = shuffled.take(leftCount).toList();
  final List<String> rightFields = shuffled
      .skip(leftCount)
      .take(rightCount)
      .toList();
  final EntityEdit left = EntityEdit(
    changedFields: leftFields,
    values: <String, Object?>{
      for (final String f in leftFields) f: 'left:$f:${rng.nextInt(1000)}',
    },
  );
  final EntityEdit right = EntityEdit(
    changedFields: rightFields,
    values: <String, Object?>{
      for (final String f in rightFields) f: 'right:$f:${rng.nextInt(1000)}',
    },
  );
  return _DisjointCase(
    left: left,
    right: right,
    baseValues: _baseFor(<String>{...leftFields, ...rightFields}),
  );
}

_OverlapCase _randomOverlapCase(Random rng) {
  final List<String> shuffled = List<String>.of(_fieldPool)..shuffle(rng);
  // Guarantee at least one shared field so a contention always exists.
  final int sharedCount = 1 + rng.nextInt(2);
  final List<String> shared = shuffled.take(sharedCount).toList();
  final List<String> localOnly = shuffled
      .skip(sharedCount)
      .take(rng.nextInt(2))
      .toList();
  final List<String> remoteOnly = shuffled
      .skip(sharedCount + localOnly.length)
      .take(rng.nextInt(2))
      .toList();

  final List<String> localFields = <String>[...shared, ...localOnly];
  final List<String> remoteFields = <String>[...shared, ...remoteOnly];
  return _OverlapCase(
    local: EntityEdit(
      changedFields: localFields,
      values: <String, Object?>{
        for (final String f in localFields) f: 'local:$f:${rng.nextInt(1000)}',
      },
    ),
    remote: EntityEdit(
      changedFields: remoteFields,
      values: <String, Object?>{
        for (final String f in remoteFields)
          f: 'remote:$f:${rng.nextInt(1000)}',
      },
    ),
    baseValues: _baseFor(<String>{...localFields, ...remoteFields}),
  );
}

EntityEdit _randomEdit(Random rng, List<String> pool) {
  final List<String> shuffled = List<String>.of(pool)..shuffle(rng);
  final int count = rng.nextInt(pool.length + 1);
  final List<String> fields = shuffled.take(count).toList();
  return EntityEdit(
    changedFields: fields,
    values: <String, Object?>{
      for (final String f in fields) f: 'v:$f:${rng.nextInt(1000)}',
    },
  );
}
