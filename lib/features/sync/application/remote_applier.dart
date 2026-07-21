import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/sync/domain/remote_change.dart';

// The applier contract owns the inbound change type it must handle, so a
// feature implementing [RemoteApplier] imports only this application contract
// (never the sync feature's domain) and still gets [RemoteChange] and the
// operation-kind vocabulary it needs to apply a change.
export 'package:forge/features/sync/domain/remote_change.dart'
    show RemoteChange;
export 'package:forge/features/sync/domain/semantic_group.dart'
    show SyncOperationKind;

/// Typed remote-applier contract exported by every feature that owns replicated
/// entities (design.md §8/§9, R-SYNC-002/R-SYNC-003).
///
/// The sync feature never imports feature DAOs. Instead, each feature's
/// application boundary exports a [RemoteApplier] for the entity types it owns;
/// the outer app composition root registers the implementations into a
/// [RemoteApplierRegistry]. A pull page is applied through these contracts
/// inside the one pull transaction, parent-before-child.
abstract interface class RemoteApplier {
  /// The entity type this applier owns (e.g. `task`, `note`). One applier per
  /// type.
  String get entityType;

  /// Applies one already-translated [change] within the pull transaction [tx].
  /// Implementations MUST be idempotent (safe to re-apply the same change) and
  /// MUST NOT perform network/file/plugin work inside the transaction.
  Future<void> apply(TransactionSession tx, RemoteChange change);
}

/// Raised when the registry is misconfigured or asked for an unknown type.
final class RemoteApplierException implements Exception {
  const RemoteApplierException(this.reason);

  final String reason;

  @override
  String toString() => 'RemoteApplierException: $reason';
}

/// A registry of typed appliers keyed by entity type. Registered once at the
/// composition root; the pull pipeline routes each change to its owning
/// applier.
final class RemoteApplierRegistry {
  RemoteApplierRegistry(Iterable<RemoteApplier> appliers) {
    for (final RemoteApplier applier in appliers) {
      if (_byType.containsKey(applier.entityType)) {
        throw RemoteApplierException(
          'Duplicate remote applier for entity type ${applier.entityType}.',
        );
      }
      _byType[applier.entityType] = applier;
    }
  }

  final Map<String, RemoteApplier> _byType = <String, RemoteApplier>{};

  /// The registered entity types, sorted for deterministic iteration.
  List<String> get entityTypes => _byType.keys.toList(growable: false)..sort();

  bool supports(String entityType) => _byType.containsKey(entityType);

  RemoteApplier? applierFor(String entityType) => _byType[entityType];

  /// Applies a page of already-translated changes in the given order within one
  /// transaction. The caller is responsible for ordering the changes
  /// parent-before-child; an unknown entity type aborts the page so no partial
  /// apply can occur.
  Future<void> applyAll(
    TransactionSession tx,
    List<RemoteChange> changes,
  ) async {
    for (final RemoteChange change in changes) {
      final RemoteApplier? applier = _byType[change.entityType];
      if (applier == null) {
        throw RemoteApplierException(
          'No remote applier registered for ${change.entityType}; aborting '
          'the page rather than applying it partially.',
        );
      }
      await applier.apply(tx, change);
    }
  }
}
