/// Deterministic coalescing of superseded, unsent outbox mutations
/// (design.md §14 "coalesces superseded unsent updates").
///
/// Only `pending` (never-sent) operations are coalescable — once an operation
/// is `in_flight` the server may have observed it, so it must not be rewritten.
/// Coalescing reduces the queued work a device must push after a burst of local
/// edits to the same entity, without ever changing the eventual converged
/// state.
///
/// The reduction is a pure, order-stable, idempotent fold per entity:
///
/// * entities are emitted in first-appearance order;
/// * within an entity, operations fold in queue order via a small state machine
///   (`insert`, `patch`, `delete`);
/// * `insert` then `patch(…)` collapses to a single `insert` with the patch's
///   fields overlaid on the insert payload;
/// * `patch` then `patch` collapses to one `patch` whose changed-field set is
///   the union and whose payload takes the later value per field;
/// * anything then `delete` collapses to `delete` (a delete of a never-sent
///   `insert` annihilates the entity entirely — there is nothing to tell the
///   server about);
/// * `delete` then `insert` collapses to `insert` (a recreation supersedes the
///   delete).
///
/// Because it only merges same-entity operations and preserves the last-writer
/// value per field, `coalesce(coalesce(x)) == coalesce(x)`.
library;

import 'package:forge/features/sync/domain/semantic_group.dart';

/// A coalescable pending mutation. This is the client-side, pre-serialization
/// shape; [payload] holds the already manifest-projected replicated fields.
final class CoalescableMutation {
  CoalescableMutation({
    required this.operationId,
    required this.sequence,
    required this.entityType,
    required this.entityId,
    required this.kind,
    Map<String, Object?> payload = const <String, Object?>{},
    Iterable<String> changedFields = const <String>[],
  }) : payload = Map<String, Object?>.unmodifiable(payload),
       changedFields = Set<String>.unmodifiable(changedFields);

  /// The queue insertion order; lower sequences fold before higher ones.
  final int sequence;
  final String operationId;
  final String entityType;
  final String entityId;
  final SyncOperationKind kind;
  final Map<String, Object?> payload;
  final Set<String> changedFields;

  CoalescableMutation _rebuild({
    required int sequence,
    required String operationId,
    required SyncOperationKind kind,
    required Map<String, Object?> payload,
    required Set<String> changedFields,
  }) => CoalescableMutation(
    operationId: operationId,
    sequence: sequence,
    entityType: entityType,
    entityId: entityId,
    kind: kind,
    payload: payload,
    changedFields: changedFields,
  );
}

/// Coalesces a queue of pending mutations. Non-pending operations must be
/// excluded by the caller before invoking this.
final class OutboxCoalescer {
  const OutboxCoalescer();

  List<CoalescableMutation> coalesce(List<CoalescableMutation> pending) {
    final List<String> order = <String>[];
    final Map<String, CoalescableMutation> folded =
        <String, CoalescableMutation>{};

    final List<CoalescableMutation> sorted =
        List<CoalescableMutation>.of(pending)
          ..sort((CoalescableMutation a, CoalescableMutation b) {
            final int bySeq = a.sequence.compareTo(b.sequence);
            return bySeq != 0 ? bySeq : a.operationId.compareTo(b.operationId);
          });

    for (final CoalescableMutation next in sorted) {
      final String key = '${next.entityType}\u0000${next.entityId}';
      final CoalescableMutation? current = folded[key];
      if (current == null) {
        order.add(key);
        folded[key] = next;
        continue;
      }
      final CoalescableMutation? merged = _fold(current, next);
      if (merged == null) {
        // Annihilated (unsent insert followed by delete): drop the entity.
        folded.remove(key);
        order.remove(key);
      } else {
        folded[key] = merged;
      }
    }

    return <CoalescableMutation>[
      for (final String key in order)
        if (folded.containsKey(key)) folded[key]!,
    ];
  }

  /// Folds [next] onto [current] for the same entity, or returns null when the
  /// pair annihilates.
  ///
  /// A surviving operation keeps [current]'s sequence (the sequence at which
  /// its run first entered the queue) so emission order and re-coalescing stay
  /// stable, while adopting [next]'s operation id as the intent to send.
  CoalescableMutation? _fold(
    CoalescableMutation current,
    CoalescableMutation next,
  ) {
    switch (next.kind) {
      case SyncOperationKind.delete:
        if (current.kind == SyncOperationKind.insert) {
          // A never-sent insert then delete: nothing to replicate.
          return null;
        }
        return next._rebuild(
          sequence: current.sequence,
          operationId: next.operationId,
          kind: SyncOperationKind.delete,
          payload: const <String, Object?>{},
          changedFields: const <String>{},
        );
      case SyncOperationKind.insert:
        // A recreation (typically after a delete) supersedes prior state.
        return next._rebuild(
          sequence: current.sequence,
          operationId: next.operationId,
          kind: SyncOperationKind.insert,
          payload: next.payload,
          changedFields: next.changedFields,
        );
      case SyncOperationKind.patch:
        switch (current.kind) {
          case SyncOperationKind.delete:
            // Patch after delete is ill-formed for a coalescing queue; keep the
            // patch as the surviving intent rather than silently dropping it.
            return next._rebuild(
              sequence: current.sequence,
              operationId: next.operationId,
              kind: SyncOperationKind.patch,
              payload: next.payload,
              changedFields: next.changedFields,
            );
          case SyncOperationKind.insert:
            // Overlay the patch fields onto the insert; it stays an insert.
            return next._rebuild(
              sequence: current.sequence,
              operationId: next.operationId,
              kind: SyncOperationKind.insert,
              payload: <String, Object?>{...current.payload, ...next.payload},
              changedFields: const <String>{},
            );
          case SyncOperationKind.patch:
            return next._rebuild(
              sequence: current.sequence,
              operationId: next.operationId,
              kind: SyncOperationKind.patch,
              payload: <String, Object?>{...current.payload, ...next.payload},
              changedFields: <String>{
                ...current.changedFields,
                ...next.changedFields,
              },
            );
        }
    }
  }
}
