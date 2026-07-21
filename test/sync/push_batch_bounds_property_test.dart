/// Bounded push batching (R-SYNC-005, design.md §14 "Sync batches by
/// byte/count"; data-model.md §6).
///
/// Generative property tests plus example anchors. The planner packs ready
/// semantic groups into a batch that never exceeds the group-count,
/// operation-count, and byte limits (given each group individually fits),
/// preserves outbox order, and is maximal — the first excluded group would have
/// breached a cap.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/push_batch_bounds.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BATCH-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.6'),
  requirements: <RequirementId>[RequirementId('R-SYNC-005')],
);

SizedSemanticGroup _group(int index, int operationCount, int byteSize) {
  final List<SyncOperation> ops = <SyncOperation>[
    for (int i = 0; i < operationCount; i += 1)
      SyncOperation(
        operationId: 'g$index-op$i',
        index: i,
        entityType: 'task',
        entityId: 'g$index-e$i',
        kind: SyncOperationKind.insert,
        payload: const <String, Object?>{'title': 'x'},
      ),
  ];
  return SizedSemanticGroup(
    group: SemanticGroup(groupId: 'g$index', snapshotEpoch: 1, operations: ops),
    byteSize: byteSize,
  );
}

void main() {
  group('PushBatchPlanner properties', () {
    testWithEvidence(
      _evidence('PROP-BOUNDS-NEVER-EXCEEDED'),
      'a planned batch never exceeds the group/operation/byte limits when '
      'every ready group individually fits, and preserves order',
      () {
        for (int seed = 0; seed < 500; seed += 1) {
          final Random rng = Random(seed);
          final PushBatchLimits limits = PushBatchLimits(
            maxGroups: 1 + rng.nextInt(10),
            maxOperations: 5 + rng.nextInt(50),
            maxBytes: 100 + rng.nextInt(5000),
          );
          final PushBatchPlanner planner = PushBatchPlanner(limits: limits);

          final int count = rng.nextInt(30);
          final List<SizedSemanticGroup> ready = <SizedSemanticGroup>[
            for (int i = 0; i < count; i += 1)
              _group(
                i,
                // Each group individually fits within the operation/byte caps.
                1 + rng.nextInt(limits.maxOperations),
                rng.nextInt(limits.maxBytes + 1),
              ),
          ];

          final PushBatchPlan plan = planner.plan(ready);

          expect(
            plan.groupCount,
            lessThanOrEqualTo(limits.maxGroups),
            reason: 'group cap exceeded seed=$seed',
          );
          expect(
            plan.operationCount,
            lessThanOrEqualTo(limits.maxOperations),
            reason: 'operation cap exceeded seed=$seed',
          );
          expect(
            plan.byteSize,
            lessThanOrEqualTo(limits.maxBytes),
            reason: 'byte cap exceeded seed=$seed',
          );

          // Order preserved: selected is a prefix of ready.
          for (int i = 0; i < plan.selected.length; i += 1) {
            expect(
              plan.selected[i].group.groupId,
              ready[i].group.groupId,
              reason: 'order not preserved seed=$seed at $i',
            );
          }
          expect(plan.remaining, ready.length - plan.selected.length);

          // Maximal: the first excluded group would breach a cap.
          if (plan.selected.length < ready.length) {
            final SizedSemanticGroup next = ready[plan.selected.length];
            final bool wouldBreach =
                plan.selected.length + 1 > limits.maxGroups ||
                plan.operationCount + next.operationCount >
                    limits.maxOperations ||
                plan.byteSize + next.byteSize > limits.maxBytes;
            expect(
              wouldBreach,
              isTrue,
              reason: 'batch was not maximal seed=$seed',
            );
          }
        }
      },
    );
  });

  group('PushBatchPlanner examples', () {
    testWithEvidence(
      _evidence('STOPS-AT-GROUP-CAP'),
      'packing stops at the group count cap',
      () {
        const PushBatchPlanner planner = PushBatchPlanner(
          limits: PushBatchLimits(
            maxGroups: 2,
            maxOperations: 100,
            maxBytes: 100000,
          ),
        );
        final PushBatchPlan plan = planner.plan(<SizedSemanticGroup>[
          _group(0, 1, 10),
          _group(1, 1, 10),
          _group(2, 1, 10),
        ]);
        expect(plan.groupCount, 2);
        expect(plan.remaining, 1);
        expect(plan.hasMore, isTrue);
      },
    );

    testWithEvidence(
      _evidence('STOPS-AT-BYTE-CAP'),
      'packing stops before a group that would breach the byte cap',
      () {
        const PushBatchPlanner planner = PushBatchPlanner(
          limits: PushBatchLimits(
            maxGroups: 100,
            maxOperations: 100,
            maxBytes: 100,
          ),
        );
        final PushBatchPlan plan = planner.plan(<SizedSemanticGroup>[
          _group(0, 1, 60),
          _group(1, 1, 60), // 120 > 100, excluded.
          _group(2, 1, 10),
        ]);
        expect(plan.byteSize, 60);
        expect(plan.groupCount, 1);
        expect(plan.remaining, 2);
      },
    );

    testWithEvidence(
      _evidence('LONE-OVERSIZED-HEAD-EMITTED'),
      'a lone oversized head group is emitted as a singleton for progress',
      () {
        const PushBatchPlanner planner = PushBatchPlanner(
          limits: PushBatchLimits(
            maxGroups: 100,
            maxOperations: 100,
            maxBytes: 50,
          ),
        );
        final PushBatchPlan plan = planner.plan(<SizedSemanticGroup>[
          _group(0, 1, 500), // Exceeds the byte cap alone.
          _group(1, 1, 10),
        ]);
        expect(plan.groupCount, 1);
        expect(plan.selected.single.group.groupId, 'g0');
        expect(plan.remaining, 1);
      },
    );

    testWithEvidence(
      _evidence('EMPTY-READY-EMPTY-PLAN'),
      'no ready groups yields an empty plan',
      () {
        const PushBatchPlanner planner = PushBatchPlanner();
        final PushBatchPlan plan = planner.plan(const <SizedSemanticGroup>[]);
        expect(plan.isEmpty, isTrue);
        expect(plan.hasMore, isFalse);
      },
    );
  });
}
