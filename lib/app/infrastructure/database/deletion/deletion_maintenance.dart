import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';

/// The deletion-kernel action that triggered maintenance.
enum DeletionAction { softDelete, restore, hardPurge }

/// A feature-supplied maintenance step run inside the deletion transaction,
/// keyed by entity type in the [TrashRegistry]'s owning [DeletionService].
///
/// The generic deletion kernel is table-driven and knows nothing about
/// feature-specific derived state (e.g. wiki-link resolution). A feature that
/// must repair such state in the *same commit* as a soft-delete, restore, or
/// hard-purge registers a hook here (R-NOTE-003 rename/delete/restore
/// integrity). Hooks run through the session-scoped repositories so their
/// writes commit atomically with the tombstone change; they must not perform
/// network/file/plugin work (design.md §5).
abstract interface class DeletionMaintenanceHook {
  Future<void> apply(
    TransactionSession session,
    ProfileId profile,
    String entityId,
    DeletionAction action,
    int nowUtc,
  );
}
