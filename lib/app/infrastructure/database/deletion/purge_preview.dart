import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// A reference to one soft-deletable entity row.
final class EntityRef implements Comparable<EntityRef> {
  const EntityRef({required this.entityType, required this.entityId});

  final String entityType;
  final String entityId;

  /// Stable canonical form used for confirmation digests and ordering.
  String get canonical => '$entityType/$entityId';

  @override
  int compareTo(EntityRef other) => canonical.compareTo(other.canonical);

  @override
  bool operator ==(Object other) =>
      other is EntityRef &&
      other.entityType == entityType &&
      other.entityId == entityId;

  @override
  int get hashCode => Object.hash(entityType, entityId);

  @override
  String toString() => canonical;
}

/// The durable obligations that block hard purge for one entity (R-GEN-003).
final class PurgeBlocks {
  const PurgeBlocks({
    required this.pendingOutbox,
    required this.openConflicts,
    required this.remoteRetention,
    required this.pendingFileOps,
  });

  const PurgeBlocks.none()
    : pendingOutbox = 0,
      openConflicts = 0,
      remoteRetention = 0,
      pendingFileOps = 0;

  final int pendingOutbox;
  final int openConflicts;
  final int remoteRetention;
  final int pendingFileOps;

  bool get isBlocked =>
      pendingOutbox > 0 ||
      openConflicts > 0 ||
      remoteRetention > 0 ||
      pendingFileOps > 0;

  /// Stable, presentation-safe reason codes for the blocks that are present.
  List<String> get reasons => <String>[
    if (pendingOutbox > 0) 'pending_outbox',
    if (openConflicts > 0) 'open_conflict',
    if (remoteRetention > 0) 'remote_retention',
    if (pendingFileOps > 0) 'file_operation',
  ];
}

/// Preview of a single hard-purge target.
final class PurgeTargetPreview {
  const PurgeTargetPreview({
    required this.ref,
    required this.exists,
    required this.isDeleted,
    required this.blocks,
  });

  final EntityRef ref;
  final bool exists;
  final bool isDeleted;
  final PurgeBlocks blocks;

  /// A target may be permanently removed only when it exists, is already
  /// soft-deleted, and carries no block.
  bool get purgeable => exists && isDeleted && !blocks.isBlocked;
}

/// Opaque confirmation binding an explicit user decision to the exact set of
/// records a preview reported as purgeable (R-GEN-003, NFR-UX-002).
final class PurgeConfirmation {
  const PurgeConfirmation(this.token);

  /// Derives the confirmation for the purgeable [refs] and their [count].
  factory PurgeConfirmation.forRefs(Iterable<EntityRef> refs, int count) {
    final List<EntityRef> sorted = refs.toList()..sort();
    final String canonical =
        '${sorted.map((EntityRef r) => r.canonical).join(',')}|$count';
    return PurgeConfirmation(_digest(canonical));
  }

  final String token;

  @override
  bool operator ==(Object other) =>
      other is PurgeConfirmation && other.token == token;

  @override
  int get hashCode => token.hashCode;

  static String _digest(String input) {
    // FNV-1a 64-bit; deterministic on the native VM. Compact and opaque, and
    // sufficient to bind a confirmation to the previewed set — not a security
    // primitive.
    int hash = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    for (final int unit in input.codeUnits) {
      hash ^= unit;
      hash = hash * prime;
    }
    final int high = (hash >> 32) & 0xffffffff;
    final int low = hash & 0xffffffff;
    return high.toRadixString(16).padLeft(8, '0') +
        low.toRadixString(16).padLeft(8, '0');
  }
}

/// The result of previewing a hard purge (R-GEN-003).
final class PurgePreview {
  PurgePreview(this.targets)
    : affectedCount = targets
          .where((PurgeTargetPreview t) => t.purgeable)
          .length,
      blockedCount = targets
          .where(
            (PurgeTargetPreview t) =>
                t.exists && t.isDeleted && t.blocks.isBlocked,
          )
          .length,
      confirmation = PurgeConfirmation.forRefs(
        targets
            .where((PurgeTargetPreview t) => t.purgeable)
            .map((PurgeTargetPreview t) => t.ref),
        targets.where((PurgeTargetPreview t) => t.purgeable).length,
      );

  final List<PurgeTargetPreview> targets;

  /// Number of records that would be permanently removed on confirmation.
  final int affectedCount;

  /// Number of soft-deleted records that cannot be purged yet due to blocks.
  final int blockedCount;

  /// The confirmation that authorizes purging exactly the purgeable set.
  final PurgeConfirmation confirmation;

  bool get hasBlocked => blockedCount > 0;

  Iterable<EntityRef> get purgeableRefs => targets
      .where((PurgeTargetPreview t) => t.purgeable)
      .map((PurgeTargetPreview t) => t.ref);
}

/// Preview of a destructive bulk operation's affected count (R-GEN-003).
final class BulkOperationPreview {
  BulkOperationPreview({required this.affectedCount, required this.refs})
    : confirmation = PurgeConfirmation.forRefs(refs, affectedCount);

  /// Number of rows the operation would affect.
  final int affectedCount;

  /// The affected rows, in canonical order.
  final List<EntityRef> refs;

  /// Confirmation binding the previewed affected set.
  final PurgeConfirmation confirmation;
}

/// Read-only previews for destructive operations (R-GEN-003, NFR-UX-002).
///
/// Every preview runs in one transaction so the reported counts and blocks are
/// a consistent snapshot. No preview mutates state.
final class PurgePreviewService {
  PurgePreviewService({
    required this.unitOfWork,
    required this.clock,
    required this.registry,
  });

  final UnitOfWork unitOfWork;
  final Clock clock;
  final TrashRegistry registry;

  /// Previews hard purge of [refs]: each target's existence, soft-deletion, and
  /// blocks, plus the total affected count and a binding confirmation.
  Future<PurgePreview> previewPurge(ProfileId profile, List<EntityRef> refs) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    return unitOfWork.transaction<PurgePreview>((
      TransactionSession session,
    ) async {
      final TrashRepository trash = session.repositories
          .resolve<TrashRepository>();
      final PurgeGuardRepository guard = session.repositories
          .resolve<PurgeGuardRepository>();
      final List<PurgeTargetPreview> previews = <PurgeTargetPreview>[];
      for (final EntityRef ref in refs) {
        final TrashableEntity descriptor = registry.require(ref.entityType);
        final TrashState state = await trash.stateOf(
          descriptor,
          profile.value,
          ref.entityId,
        );
        PurgeBlocks blocks = const PurgeBlocks.none();
        if (state.exists && state.isDeleted) {
          blocks = await _blocksFor(guard, profile, ref, now);
        }
        previews.add(
          PurgeTargetPreview(
            ref: ref,
            exists: state.exists,
            isDeleted: state.isDeleted,
            blocks: blocks,
          ),
        );
      }
      return PurgePreview(previews);
    });
  }

  /// Previews a destructive bulk delete: the live rows among [refs] that the
  /// operation would soft-delete, with a binding confirmation.
  Future<BulkOperationPreview> previewBulkDelete(
    ProfileId profile,
    List<EntityRef> refs,
  ) {
    return unitOfWork.transaction<BulkOperationPreview>((
      TransactionSession session,
    ) async {
      final TrashRepository trash = session.repositories
          .resolve<TrashRepository>();
      final List<EntityRef> affected = <EntityRef>[];
      for (final EntityRef ref in refs) {
        final TrashableEntity descriptor = registry.require(ref.entityType);
        final TrashState state = await trash.stateOf(
          descriptor,
          profile.value,
          ref.entityId,
        );
        if (state.exists && !state.isDeleted) {
          affected.add(ref);
        }
      }
      affected.sort();
      return BulkOperationPreview(
        affectedCount: affected.length,
        refs: affected,
      );
    });
  }

  Future<PurgeBlocks> _blocksFor(
    PurgeGuardRepository guard,
    ProfileId profile,
    EntityRef ref,
    int nowUtc,
  ) async {
    final int pendingOutbox = await guard.pendingOutboxCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    final int openConflicts = await guard.openConflictCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    final int retention = await guard.retentionCount(
      profile.value,
      ref.entityType,
      ref.entityId,
      nowUtc,
    );
    final int fileOps = await guard.pendingFileOpsCount(
      profile.value,
      ref.entityType,
      ref.entityId,
    );
    return PurgeBlocks(
      pendingOutbox: pendingOutbox,
      openConflicts: openConflicts,
      remoteRetention: retention,
      pendingFileOps: fileOps,
    );
  }
}
