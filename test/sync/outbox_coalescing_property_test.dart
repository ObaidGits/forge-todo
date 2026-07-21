/// Outbox coalescing determinism (design.md §14; R-SYNC-002).
///
/// A generative property test plus explicit example anchors. Coalescing of
/// unsent mutations must be deterministic, idempotent, order-stable per entity,
/// never grow the queue, and never leave two operations for the same entity.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/outbox_coalescing.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-COALESCE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-002')],
);

const OutboxCoalescer _coalescer = OutboxCoalescer();

String _entityKey(CoalescableMutation m) =>
    '${m.entityType}\u0000${m.entityId}';

List<CoalescableMutation> _randomQueue(Random rng) {
  final int entityCount = 1 + rng.nextInt(4);
  final int opCount = rng.nextInt(12);
  final List<CoalescableMutation> queue = <CoalescableMutation>[];
  for (int i = 0; i < opCount; i += 1) {
    final String entityId = 'e${rng.nextInt(entityCount)}';
    final SyncOperationKind kind =
        SyncOperationKind.values[rng.nextInt(SyncOperationKind.values.length)];
    final Map<String, Object?> payload = <String, Object?>{};
    if (kind != SyncOperationKind.delete) {
      final int fields = 1 + rng.nextInt(3);
      for (int f = 0; f < fields; f += 1) {
        payload['field$f'] = rng.nextInt(1000);
      }
    }
    queue.add(
      CoalescableMutation(
        operationId: 'op-$i',
        sequence: i,
        entityType: 'task',
        entityId: entityId,
        kind: kind,
        payload: payload,
        changedFields: kind == SyncOperationKind.patch
            ? payload.keys
            : const <String>[],
      ),
    );
  }
  return queue;
}

void main() {
  group('OutboxCoalescer properties', () {
    testWithEvidence(
      _evidence('PROP-DETERMINISTIC-IDEMPOTENT'),
      'coalescing is deterministic, idempotent, order-stable, and non-growing '
      'across randomized queues',
      () {
        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);
          final List<CoalescableMutation> queue = _randomQueue(rng);

          final List<CoalescableMutation> once = _coalescer.coalesce(queue);
          // Determinism: same input, same output.
          final List<CoalescableMutation> again = _coalescer.coalesce(queue);
          expect(
            again.map(_describe).toList(),
            once.map(_describe).toList(),
            reason: 'non-deterministic for seed=$seed',
          );

          // Idempotence: coalesce(coalesce(x)) == coalesce(x).
          final List<CoalescableMutation> twice = _coalescer.coalesce(once);
          expect(
            twice.map(_describe).toList(),
            once.map(_describe).toList(),
            reason: 'not idempotent for seed=$seed',
          );

          // Never grows.
          expect(
            once.length,
            lessThanOrEqualTo(queue.length),
            reason: 'grew the queue for seed=$seed',
          );

          // At most one surviving operation per entity.
          final Set<String> keys = <String>{};
          for (final CoalescableMutation m in once) {
            expect(
              keys.add(_entityKey(m)),
              isTrue,
              reason: 'duplicate entity survived for seed=$seed',
            );
          }

          // Every survivor's fields are a subset of the union of the fields
          // that entity's operations contributed (no invented state).
          for (final CoalescableMutation m in once) {
            final Set<String> contributed = <String>{};
            for (final CoalescableMutation q in queue) {
              if (_entityKey(q) == _entityKey(m)) {
                contributed.addAll(q.payload.keys);
              }
            }
            expect(
              m.payload.keys.every(contributed.contains),
              isTrue,
              reason: 'invented a field for seed=$seed',
            );
          }
        }
      },
    );
  });

  group('OutboxCoalescer examples', () {
    testWithEvidence(
      _evidence('INSERT-DELETE-ANNIHILATES'),
      'an unsent insert followed by a delete cancels out entirely',
      () {
        final List<CoalescableMutation> result = _coalescer.coalesce(
          <CoalescableMutation>[
            CoalescableMutation(
              operationId: 'op-0',
              sequence: 0,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.insert,
              payload: const <String, Object?>{'title': 'draft'},
            ),
            CoalescableMutation(
              operationId: 'op-1',
              sequence: 1,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.delete,
            ),
          ],
        );
        expect(result, isEmpty);
      },
    );

    testWithEvidence(
      _evidence('PATCH-PATCH-UNION-LATER-WINS'),
      'consecutive patches union changed fields and take the later value',
      () {
        final List<CoalescableMutation> result = _coalescer.coalesce(
          <CoalescableMutation>[
            CoalescableMutation(
              operationId: 'op-0',
              sequence: 0,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.patch,
              payload: const <String, Object?>{'title': 'A', 'priority': 1},
              changedFields: const <String>['title', 'priority'],
            ),
            CoalescableMutation(
              operationId: 'op-1',
              sequence: 1,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.patch,
              payload: const <String, Object?>{'title': 'B', 'notes': 'x'},
              changedFields: const <String>['title', 'notes'],
            ),
          ],
        );
        expect(result, hasLength(1));
        final CoalescableMutation only = result.single;
        expect(only.kind, SyncOperationKind.patch);
        expect(only.payload['title'], 'B');
        expect(only.payload['priority'], 1);
        expect(only.payload['notes'], 'x');
        expect(only.changedFields, <String>{'title', 'priority', 'notes'});
      },
    );

    testWithEvidence(
      _evidence('INSERT-PATCH-STAYS-INSERT'),
      'an insert then patch overlays fields but stays an insert',
      () {
        final List<CoalescableMutation> result = _coalescer.coalesce(
          <CoalescableMutation>[
            CoalescableMutation(
              operationId: 'op-0',
              sequence: 0,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.insert,
              payload: const <String, Object?>{'title': 'A', 'priority': 0},
            ),
            CoalescableMutation(
              operationId: 'op-1',
              sequence: 1,
              entityType: 'task',
              entityId: 'e0',
              kind: SyncOperationKind.patch,
              payload: const <String, Object?>{'priority': 5},
              changedFields: const <String>['priority'],
            ),
          ],
        );
        expect(result, hasLength(1));
        expect(result.single.kind, SyncOperationKind.insert);
        expect(result.single.payload['title'], 'A');
        expect(result.single.payload['priority'], 5);
      },
    );

    testWithEvidence(
      _evidence('DISTINCT-ENTITIES-PRESERVED'),
      'operations for distinct entities are preserved in first-seen order',
      () {
        final List<CoalescableMutation> result = _coalescer.coalesce(
          <CoalescableMutation>[
            CoalescableMutation(
              operationId: 'op-0',
              sequence: 0,
              entityType: 'task',
              entityId: 'e1',
              kind: SyncOperationKind.insert,
              payload: const <String, Object?>{'title': 'one'},
            ),
            CoalescableMutation(
              operationId: 'op-1',
              sequence: 1,
              entityType: 'task',
              entityId: 'e2',
              kind: SyncOperationKind.insert,
              payload: const <String, Object?>{'title': 'two'},
            ),
          ],
        );
        expect(
          result.map((CoalescableMutation m) => m.entityId).toList(),
          <String>['e1', 'e2'],
        );
      },
    );
  });
}

String _describe(CoalescableMutation m) =>
    '${m.entityId}:${m.kind.name}:${_sortedPayload(m.payload)}';

String _sortedPayload(Map<String, Object?> payload) {
  final List<String> keys = payload.keys.toList()..sort();
  return keys.map((String k) => '$k=${payload[k]}').join(',');
}
