import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// Advances outbox and pending-command journal state together in one local
/// transaction (design.md §5, data-model §3).
///
/// Sending advances a group `pending → in_flight` retry-safely; a committed
/// server acknowledgement advances its outbox rows and journal entry to
/// `acknowledged`; a preserved collision becomes `terminal_conflict`. Because
/// both tables move in the same transaction they can never diverge.
final class SyncAcknowledgementService {
  SyncAcknowledgementService({
    required this.unitOfWork,
    required this.clock,
    Duration retentionWindow = const Duration(days: 180),
  }) : _retentionMicros = retentionWindow.inMicroseconds;

  final UnitOfWork unitOfWork;
  final Clock clock;
  final int _retentionMicros;

  /// Marks a group as being sent: journal and outbox move `pending → in_flight`.
  Future<void> beginSend(ProfileId profile, String groupId) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    return unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories.resolve<OutboxRepository>().advanceGroup(
        profileId: profile.value,
        groupId: groupId,
        state: SyncWriteState.inFlight,
        nowUtc: now,
      );
      await session.repositories
          .resolve<PendingCommandJournalRepository>()
          .markInFlight(profile.value, groupId);
    });
  }

  /// Records a committed server acceptance for [groupId].
  Future<void> acknowledgeAccepted(ProfileId profile, String groupId) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    final int retainedUntil = now + _retentionMicros;
    return unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories.resolve<OutboxRepository>().advanceGroup(
        profileId: profile.value,
        groupId: groupId,
        state: SyncWriteState.acknowledged,
        nowUtc: now,
      );
      await session.repositories
          .resolve<PendingCommandJournalRepository>()
          .markAcknowledged(
            profileId: profile.value,
            syncGroupId: groupId,
            acknowledgedAtUtc: now,
            retainedUntilUtc: retainedUntil,
          );
    });
  }

  /// Records a preserved collision for [groupId] as terminal conflict.
  Future<void> acknowledgeConflict(ProfileId profile, String groupId) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    final int retainedUntil = now + _retentionMicros;
    return unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories.resolve<OutboxRepository>().advanceGroup(
        profileId: profile.value,
        groupId: groupId,
        state: SyncWriteState.terminalConflict,
        nowUtc: now,
      );
      await session.repositories
          .resolve<PendingCommandJournalRepository>()
          .markTerminalConflict(
            profileId: profile.value,
            syncGroupId: groupId,
            retainedUntilUtc: retainedUntil,
          );
    });
  }
}
