import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/sync/journal_maintenance.dart';
import 'package:forge/core/application/unit_of_work.dart';

import 'command_test_support.dart';

/// Transactional acknowledgement, restart recovery, and journaled pruning of
/// the outbox and pending-command journal over a real Drift database.
///
/// **Validates: Requirements R-SYNC-002, R-SYNC-003, R-SYNC-006, R-GEN-005**
void main() {
  late CommandHarness h;

  setUp(() async {
    h = await CommandHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> commitGroup(String id, String groupId) async {
    await h.bus.execute(
      command(profileId: h.profileId, id: id, requestHash: id),
      (TransactionSession session) async => semanticWrite(
        entityId: 'e-$id',
        activityId: 'a-$id',
        groupId: groupId,
        operationId: 'op-$id',
      ),
    );
  }

  Future<String?> journalState(String groupId) async {
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT state FROM pending_command_journal WHERE sync_group_id = ?',
      <Object?>[groupId],
    );
    return row?['state'] as String?;
  }

  Future<String?> outboxState(String groupId) async {
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT state FROM outbox_mutations WHERE group_id = ?',
      <Object?>[groupId],
    );
    return row?['state'] as String?;
  }

  group('given a committed sync group', () {
    test('when sending begins then journal and outbox both move to '
        'in_flight', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.beginSend(h.profileId, 'g1');
      expect(await journalState('g1'), 'in_flight');
      expect(await outboxState('g1'), 'in_flight');
    });

    test('when the server accepts then both move to acknowledged with '
        'retention', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.beginSend(h.profileId, 'g1');
      await h.acknowledgements.acknowledgeAccepted(h.profileId, 'g1');
      expect(await journalState('g1'), 'acknowledged');
      expect(await outboxState('g1'), 'acknowledged');
      final Map<String, Object?>? row = await h.firstRow(
        'SELECT retained_until_utc AS n FROM pending_command_journal '
        'WHERE sync_group_id = ?',
        <Object?>['g1'],
      );
      expect(row!['n'], isNotNull);
    });

    test('when a collision is preserved then both move to '
        'terminal_conflict', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.beginSend(h.profileId, 'g1');
      await h.acknowledgements.acknowledgeConflict(h.profileId, 'g1');
      expect(await journalState('g1'), 'terminal_conflict');
      expect(await outboxState('g1'), 'terminal_conflict');
    });
  });

  group('given interrupted in-flight work at restart', () {
    test('when recovery runs then in_flight rows return to pending', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.beginSend(h.profileId, 'g1');

      final RecoveryReport report = await h.maintenance.recoverInterrupted(
        h.profileId,
      );
      expect(report.outboxReset, 1);
      expect(report.journalReset, 1);
      expect(await journalState('g1'), 'pending');
      expect(await outboxState('g1'), 'pending');
    });

    test('when acknowledged work exists then recovery leaves it '
        'untouched', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.acknowledgeAccepted(h.profileId, 'g1');
      await h.maintenance.recoverInterrupted(h.profileId);
      expect(await journalState('g1'), 'acknowledged');
    });
  });

  group('given journaled pruning', () {
    test('when retention has not elapsed then acknowledged journals '
        'remain', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.acknowledgeAccepted(h.profileId, 'g1');
      final int pruned = await h.maintenance.prune(h.profileId);
      expect(pruned, 0);
      expect(await journalState('g1'), 'acknowledged');
    });

    test('when retention has elapsed and the group is accepted then the '
        'journal and outbox are pruned', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.acknowledgeAccepted(h.profileId, 'g1');
      h.clock.advance(const Duration(days: 181));
      final int pruned = await h.maintenance.prune(h.profileId);
      expect(pruned, 1);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM pending_command_journal'),
        0,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        0,
      );
    });

    test('when the command receipt survives pruning then replay is still '
        'stable', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.acknowledgeAccepted(h.profileId, 'g1');
      h.clock.advance(const Duration(days: 181));
      await h.maintenance.prune(h.profileId);
      // The receipt is retained beyond the journal so replay never re-runs.
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        1,
      );
      final result = await h.bus.execute(
        command(profileId: h.profileId, id: 'c1', requestHash: 'c1'),
        (TransactionSession session) async =>
            fail('replay must not run the body'),
      );
      expect(result.valueOrNull!.replayed, isTrue);
    });

    test('when an open conflict remains then terminal-conflict journals are '
        'retained', () async {
      await commitGroup('c1', 'g1');
      await h.acknowledgements.acknowledgeConflict(h.profileId, 'g1');
      h.clock.advance(const Duration(days: 181));
      // Insert an open conflict for this profile.
      await h.db.customStatement(
        'INSERT INTO sync_conflicts '
        '(id, profile_id, remote_artifact_id, entity_type, entity_id, fields, '
        'policy, status, created_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'cf1',
          h.profileId.value,
          'art-1',
          'task',
          'e-c1',
          'title',
          'scalar',
          'open',
          0,
        ],
      );
      final int pruned = await h.maintenance.prune(h.profileId);
      expect(pruned, 0);
      expect(await journalState('g1'), 'terminal_conflict');
    });
  });
}
