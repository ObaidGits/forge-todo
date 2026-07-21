/// Bounded batching for push (design.md §14 "Sync batches by byte/count";
/// data-model.md §6 "The server … validates request/group/operation bytes …").
///
/// The client packs ready semantic groups into a push batch that never exceeds
/// the negotiated protocol limits: a maximum number of groups, a maximum total
/// operation count, and a maximum total byte size. Groups are atomic
/// (all-or-reject) and therefore indivisible, so packing is a greedy,
/// order-preserving prefix/subsequence selection — the outbox order is honored
/// and no group is split.
///
/// Per-group limits (a single group's own operation/byte size) are enforced
/// where groups are built and by the server; this planner only bounds the
/// *aggregate* batch. To guarantee forward progress it will emit a lone
/// oversized head group as a singleton batch so a too-large group surfaces a
/// server rejection rather than silently stalling the queue forever.
library;

import 'package:forge/features/sync/domain/semantic_group.dart';

/// The aggregate per-batch limits negotiated for protocol v2. Conservative
/// client-side caps that stay at or under the server's validation thresholds.
final class PushBatchLimits {
  const PushBatchLimits({
    this.maxGroups = defaultMaxGroups,
    this.maxOperations = defaultMaxOperations,
    this.maxBytes = defaultMaxBytes,
  }) : assert(maxGroups > 0, 'maxGroups must be positive'),
       assert(maxOperations > 0, 'maxOperations must be positive'),
       assert(maxBytes > 0, 'maxBytes must be positive');

  static const int defaultMaxGroups = 100;
  static const int defaultMaxOperations = 1000;
  static const int defaultMaxBytes = 1 << 20; // 1 MiB

  /// The default protocol-v2 client limits.
  static const PushBatchLimits protocolV2 = PushBatchLimits();

  final int maxGroups;
  final int maxOperations;
  final int maxBytes;
}

/// A semantic group paired with its measured serialized byte size, ready to be
/// packed into a batch. Byte size is measured once at build time so the planner
/// stays independent of the serializer.
final class SizedSemanticGroup {
  SizedSemanticGroup({required this.group, required this.byteSize}) {
    if (byteSize < 0) {
      throw ArgumentError.value(byteSize, 'byteSize', 'Must be nonnegative.');
    }
  }

  final SemanticGroup group;

  /// The serialized size of this group's push payload, in bytes.
  final int byteSize;

  int get operationCount => group.operationCount;
}

/// The result of planning a batch: the groups selected for this push plus
/// whether more ready groups remain for a subsequent batch.
final class PushBatchPlan {
  PushBatchPlan({
    required List<SizedSemanticGroup> selected,
    required this.remaining,
  }) : selected = List<SizedSemanticGroup>.unmodifiable(selected);

  final List<SizedSemanticGroup> selected;

  /// The count of ready groups not included in this batch (they roll into the
  /// next push).
  final int remaining;

  int get groupCount => selected.length;

  int get operationCount => selected.fold(
    0,
    (int sum, SizedSemanticGroup g) => sum + g.operationCount,
  );

  int get byteSize =>
      selected.fold(0, (int sum, SizedSemanticGroup g) => sum + g.byteSize);

  bool get hasMore => remaining > 0;

  bool get isEmpty => selected.isEmpty;
}

/// Packs ready groups into a bounded batch that never exceeds the aggregate
/// limits (except a lone oversized head group, which is emitted as a singleton
/// so it is not stuck forever).
final class PushBatchPlanner {
  const PushBatchPlanner({this.limits = PushBatchLimits.protocolV2});

  final PushBatchLimits limits;

  /// Selects the longest order-preserving prefix of [ready] that fits within
  /// the group-count, operation-count, and byte limits. Packing stops at the
  /// first group that would breach any cap; later groups roll into the next
  /// batch. If the very first group alone exceeds the operation or byte cap it
  /// is still emitted as a singleton batch to guarantee forward progress.
  PushBatchPlan plan(List<SizedSemanticGroup> ready) {
    final List<SizedSemanticGroup> selected = <SizedSemanticGroup>[];
    int operations = 0;
    int bytes = 0;

    for (final SizedSemanticGroup candidate in ready) {
      if (selected.length >= limits.maxGroups) {
        break;
      }
      final int nextOperations = operations + candidate.operationCount;
      final int nextBytes = bytes + candidate.byteSize;
      final bool fits =
          nextOperations <= limits.maxOperations &&
          nextBytes <= limits.maxBytes;
      if (fits) {
        selected.add(candidate);
        operations = nextOperations;
        bytes = nextBytes;
        continue;
      }
      // The candidate does not fit. If nothing is selected yet it is a lone
      // oversized head group: emit it alone so it can surface a server result
      // rather than blocking the queue indefinitely.
      if (selected.isEmpty) {
        selected.add(candidate);
      }
      break;
    }

    return PushBatchPlan(
      selected: selected,
      remaining: ready.length - selected.length,
    );
  }
}
