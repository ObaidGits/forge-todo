import 'package:forge/app/infrastructure/database/deletion/deletion_maintenance.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/infrastructure/note_write_repository.dart';

/// Repairs inbound `[[wiki-link]]` resolution in the same commit as a note
/// soft-delete, restore, or hard-purge (R-NOTE-003 rename/delete/restore
/// integrity).
///
/// * **Soft-delete / trash:** the note is now hidden from live-title matching,
///   so every link that referenced its title is re-resolved. A link that was
///   uniquely resolved to it deterministically drops to `unresolved` — a
///   recoverable reference that never corrupts the linking note — while a link
///   that was ambiguous may now resolve to the remaining single match.
/// * **Restore:** the note is a live match again, so links referencing its
///   title re-resolve (rebinding a previously unresolved reference, or becoming
///   ambiguous if another note shares the title).
/// * **Hard-purge:** the row is gone, so links that still pointed at it are
///   recomputed by their stored normalized target and drop to `unresolved`.
///
/// The hook resolves the transaction-scoped [NoteWriteRepository] from the
/// deletion command's session, so all repair writes commit atomically with the
/// tombstone change.
final class NoteLinkDeletionMaintenance implements DeletionMaintenanceHook {
  const NoteLinkDeletionMaintenance();

  @override
  Future<void> apply(
    TransactionSession session,
    ProfileId profile,
    String entityId,
    DeletionAction action,
    int nowUtc,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    switch (action) {
      case DeletionAction.softDelete:
      case DeletionAction.restore:
        final String? normalized = await repo.normalizedTitleOf(
          profile.value,
          entityId,
        );
        if (normalized == null) {
          return;
        }
        await repo.reResolveByNormalizedTarget(profile.value, normalized);
      case DeletionAction.hardPurge:
        // The note row is already gone; repair links that still referenced it.
        await repo.reResolveDanglingTarget(profile.value, entityId);
    }
  }
}
