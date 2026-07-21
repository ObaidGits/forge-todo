import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// Summary of a restart-recovery pass.
final class RecoveryReport {
  const RecoveryReport({required this.outboxReset, required this.journalReset});

  final int outboxReset;
  final int journalReset;
}

/// Restart recovery and journaled pruning of the outbox and pending-command
/// journal (data-model §3).
///
/// Recovery re-arms interrupted `in_flight` work for its idempotent retry.
/// Pruning is an explicit, restart-safe maintenance command — never an
/// acknowledgement side effect — that removes an acknowledged journal only
/// after every group operation is durably accepted and retention has elapsed,
/// and removes a terminal-conflict journal only after its conflict is resolved
/// plus the same retention.
final class JournalMaintenance {
  JournalMaintenance({required this.unitOfWork, required this.clock});

  final UnitOfWork unitOfWork;
  final Clock clock;

  /// Returns interrupted `in_flight` outbox and journal rows to `pending`.
  Future<RecoveryReport> recoverInterrupted(ProfileId profile) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    return unitOfWork.transaction<RecoveryReport>((
      TransactionSession session,
    ) async {
      final int outbox = await session.repositories
          .resolve<OutboxRepository>()
          .resetInterrupted(profile.value, now);
      final int journal = await session.repositories
          .resolve<PendingCommandJournalRepository>()
          .resetInterrupted(profile.value);
      return RecoveryReport(outboxReset: outbox, journalReset: journal);
    });
  }

  /// Prunes acknowledged and eligible terminal-conflict journals. Returns the
  /// number of journal entries removed.
  Future<int> prune(ProfileId profile) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    return unitOfWork.transaction<int>((TransactionSession session) async {
      final PendingCommandJournalRepository journal = session.repositories
          .resolve<PendingCommandJournalRepository>();
      final OutboxRepository outbox = session.repositories
          .resolve<OutboxRepository>();
      final SyncConflictRepository conflicts = session.repositories
          .resolve<SyncConflictRepository>();

      int pruned = 0;

      // Acknowledged journals: require every group op durably accepted.
      final List<JournalEntry> acknowledged = await journal.retentionElapsed(
        profileId: profile.value,
        state: SyncWriteState.acknowledged,
        nowUtc: now,
      );
      for (final JournalEntry entry in acknowledged) {
        final String? groupId = entry.syncGroupId;
        if (groupId != null) {
          final bool accepted = await outbox.groupAllInState(
            profileId: profile.value,
            groupId: groupId,
            state: SyncWriteState.acknowledged,
          );
          if (!accepted) {
            continue;
          }
          await outbox.deleteGroup(profile.value, groupId);
        }
        await journal.delete(profile.value, entry.commandId);
        pruned += 1;
      }

      // Terminal-conflict journals: require no unresolved conflict remains.
      final int openConflicts = await conflicts.openCount(profile.value);
      if (openConflicts == 0) {
        final List<JournalEntry> terminal = await journal.retentionElapsed(
          profileId: profile.value,
          state: SyncWriteState.terminalConflict,
          nowUtc: now,
        );
        for (final JournalEntry entry in terminal) {
          final String? groupId = entry.syncGroupId;
          if (groupId != null) {
            await outbox.deleteGroup(profile.value, groupId);
          }
          await journal.delete(profile.value, entry.commandId);
          pruned += 1;
        }
      }

      return pruned;
    });
  }
}
