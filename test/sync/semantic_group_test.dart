/// Semantic transaction group invariants (R-SYNC-003, R-SYNC-004).
///
/// A group carries contiguous indices, is ordered parent-before-child, and is
/// acknowledged only when accepted or preserved as a conflict.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-GROUP-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-003')],
);

SyncOperation _op({
  required int index,
  required String entityId,
  String? parent,
  SyncOperationKind kind = SyncOperationKind.insert,
}) => SyncOperation(
  operationId: 'op-$index',
  index: index,
  entityType: 'task',
  entityId: entityId,
  kind: kind,
  payload: const <String, Object?>{'title': 'x'},
  parentEntityId: parent,
);

void main() {
  group('SemanticGroup invariants', () {
    testWithEvidence(
      _evidence('CONTIGUOUS-INDICES'),
      'a group requires contiguous 0-based operation indices',
      () {
        expect(
          () => SemanticGroup(
            groupId: 'g0',
            snapshotEpoch: 1,
            operations: <SyncOperation>[
              _op(index: 0, entityId: 'a'),
              _op(index: 2, entityId: 'b'),
            ],
          ),
          throwsA(isA<SemanticGroupException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('PARENT-BEFORE-CHILD'),
      'a child operation may not precede its in-group parent',
      () {
        expect(
          () => SemanticGroup(
            groupId: 'g0',
            snapshotEpoch: 1,
            operations: <SyncOperation>[
              _op(index: 0, entityId: 'child', parent: 'parent'),
              _op(index: 1, entityId: 'parent'),
            ],
          ),
          throwsA(isA<SemanticGroupException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('PARENT-BEFORE-CHILD-OK'),
      'parent-before-child ordering builds a valid group',
      () {
        final SemanticGroup group = SemanticGroup(
          groupId: 'g0',
          snapshotEpoch: 1,
          operations: <SyncOperation>[
            _op(index: 0, entityId: 'parent'),
            _op(index: 1, entityId: 'child', parent: 'parent'),
          ],
        );
        expect(group.operationCount, 2);
      },
    );

    testWithEvidence(
      _evidence('DEFERRED-PARENT-OUTSIDE-GROUP-OK'),
      'a parent reference outside the group does not violate in-group ordering',
      () {
        final SemanticGroup group = SemanticGroup(
          groupId: 'g0',
          snapshotEpoch: 1,
          operations: <SyncOperation>[
            _op(index: 0, entityId: 'child', parent: 'external-parent'),
          ],
        );
        expect(group.operationCount, 1);
      },
    );

    testWithEvidence(
      _evidence('EMPTY-REJECTED'),
      'an empty group is rejected',
      () {
        expect(
          () => SemanticGroup(
            groupId: 'g0',
            snapshotEpoch: 1,
            operations: const <SyncOperation>[],
          ),
          throwsA(isA<SemanticGroupException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('PATCH-REQUIRES-FIELDS'),
      'a patch operation must change at least one field',
      () {
        expect(
          () => SyncOperation(
            operationId: 'op-0',
            index: 0,
            entityType: 'task',
            entityId: 'a',
            kind: SyncOperationKind.patch,
            payload: const <String, Object?>{},
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  group('SemanticGroupResult acknowledgement', () {
    testWithEvidence(
      _evidence('ACK-ACCEPTED-AND-CONFLICT'),
      'accepted and conflict results are acknowledgeable; rejects are not',
      () {
        expect(
          const SemanticGroupResult(
            groupId: 'g',
            outcome: SemanticGroupOutcome.accepted,
          ).isAcknowledgeable,
          isTrue,
        );
        expect(
          const SemanticGroupResult(
            groupId: 'g',
            outcome: SemanticGroupOutcome.conflict,
            conflictArtifactId: 'c1',
          ).isAcknowledgeable,
          isTrue,
        );
        expect(
          const SemanticGroupResult(
            groupId: 'g',
            outcome: SemanticGroupOutcome.rejected,
          ).isAcknowledgeable,
          isFalse,
        );
        expect(
          const SemanticGroupResult(
            groupId: 'g',
            outcome: SemanticGroupOutcome.staleEpoch,
          ).isAcknowledgeable,
          isFalse,
        );
      },
    );
  });
}
