import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/result.dart';

import 'command_test_support.dart';

/// Command-bus receipt check and atomic semantic-write behavior over a real
/// Drift database.
///
/// **Validates: Requirements R-GEN-005, R-NOTE-004, R-SYNC-002, R-SYNC-003**
void main() {
  late CommandHarness h;

  setUp(() async {
    h = await CommandHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given a durable command receipt', () {
    test('when first executed then it stores the stable committed '
        'result', () async {
      final Result<CommittedCommandResult> result = await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1'),
        (TransactionSession session) async => semanticWrite(),
      );
      final CommittedCommandResult value = result.valueOrNull!;
      expect(value.replayed, isFalse);
      expect(value.resultCode, 'ok');
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        1,
      );
    });

    test('when replayed with a matching hash then it returns the stored '
        'result without duplicating effects', () async {
      await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1', requestHash: 'H'),
        (TransactionSession session) async => semanticWrite(),
      );
      final Result<CommittedCommandResult> replay = await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1', requestHash: 'H'),
        (TransactionSession session) async =>
            fail('body must not run on replay'),
      );
      final CommittedCommandResult value = replay.valueOrNull!;
      expect(value.replayed, isTrue);
      expect(value.commitSeq, 1);
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM activity_events'), 1);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        1,
      );
    });

    test('when replayed with a different hash then it is rejected as a '
        'conflict', () async {
      await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1', requestHash: 'H1'),
        (TransactionSession session) async => semanticWrite(),
      );
      final Result<CommittedCommandResult> mismatch = await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1', requestHash: 'H2'),
        (TransactionSession session) async => semanticWrite(),
      );
      expect(mismatch.failureOrNull?.kind, FailureKind.conflict);
    });
  });

  group('given one sync-eligible command', () {
    test('when it commits then domain, activity, dirty, outbox, journal, '
        'receipt, and commit_seq are written atomically', () async {
      await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1'),
        (TransactionSession session) async => semanticWrite(),
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM commit_log'), 1);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        1,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM pending_command_journal'),
        1,
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM activity_events'), 1);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM projection_dirty'),
        1,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        1,
      );

      final Map<String, Object?>? journal = await h.firstRow(
        'SELECT state, sync_group_id, commit_seq FROM pending_command_journal',
      );
      expect(journal!['state'], 'pending');
      expect(journal['sync_group_id'], 'grp-1');
      expect(journal['commit_seq'], 1);

      final Map<String, Object?>? dirty = await h.firstRow(
        'SELECT projection, source_commit_seq FROM projection_dirty',
      );
      expect(dirty!['projection'], 'search');
      expect(dirty['source_commit_seq'], 1);
    });
  });

  group('given a local-only command', () {
    test('when it commits then a receipt and commit_log exist but no journal '
        'or outbox rows', () async {
      await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-local'),
        (TransactionSession session) async =>
            semanticWrite(syncEligible: false),
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        1,
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM commit_log'), 1);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM pending_command_journal'),
        0,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        0,
      );
    });
  });

  group('given a failing command body', () {
    test('when it throws then no partial write survives', () async {
      await expectLater(
        h.bus.execute(command(profileId: h.profileId, id: 'cmd-1'), (
          TransactionSession session,
        ) async {
          // Write a real row, then fail: the row must not survive rollback.
          await session.repositories.resolve<CommandReceiptRepository>().insert(
            profileId: h.profileId.value,
            commandId: 'partial',
            requestHash: 'x',
            resultCode: 'ok',
            payloadVersion: 1,
            commitSeq: session.commitSeq,
            createdAtUtc: 0,
          );
          throw StateError('domain failure');
        }),
        throwsA(isA<StateError>()),
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM commit_log'), 0);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        0,
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM activity_events'), 0);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        0,
      );
    });
  });

  group('given a non-local write origin', () {
    test(
      'when it attempts to enqueue outbox work then it is rejected',
      () async {
        final Result<CommittedCommandResult> result = await h.bus.execute(
          command(profileId: h.profileId, id: 'cmd-1'),
          origin: WriteOrigin.remoteApply,
          (TransactionSession session) async => semanticWrite(),
        );
        expect(result.failureOrNull?.code, 'command.illegal_outbox_origin');
        expect(await h.scalarInt('SELECT COUNT(*) AS n FROM commit_log'), 0);
      },
    );
  });

  group('given after-commit hints', () {
    test('when a command commits then hints dispatch exactly once after '
        'commit', () async {
      await h.bus.execute(
        command(profileId: h.profileId, id: 'cmd-1'),
        (TransactionSession session) async => semanticWrite(
          hints: const <AfterCommitHint>[
            AfterCommitHint(
              kind: 'projection',
              entityType: 'task',
              entityId: 'e1',
            ),
            AfterCommitHint(
              kind: 'projection',
              entityType: 'task',
              entityId: 'e1',
            ),
          ],
        ),
      );
      expect(h.hintHandler.received.length, 1);
      expect(h.hintHandler.received.single.entityId, 'e1');
    });

    test('when a hint handler throws then the committed result still '
        'succeeds', () async {
      final ThrowingHintHandler thrower = ThrowingHintHandler();
      final CommandHarness local = await CommandHarness.open(
        handlers: <AfterCommitHandler>[thrower],
      );
      try {
        final Result<CommittedCommandResult> result = await local.bus.execute(
          command(profileId: local.profileId, id: 'cmd-1'),
          (TransactionSession session) async => semanticWrite(
            hints: const <AfterCommitHint>[
              AfterCommitHint(
                kind: 'projection',
                entityType: 'task',
                entityId: 'e1',
              ),
            ],
          ),
        );
        expect(result.valueOrNull, isNotNull);
        expect(thrower.called, isTrue);
        // The durable dirty marker remains for startup reconciliation.
        expect(
          await local.scalarInt('SELECT COUNT(*) AS n FROM projection_dirty'),
          1,
        );
      } finally {
        await local.close();
      }
    });

    test('when a command is replayed then no hint is dispatched', () async {
      final DurableCommand cmd = command(
        profileId: h.profileId,
        id: 'cmd-1',
        requestHash: 'H',
      );
      await h.bus.execute(
        cmd,
        (TransactionSession session) async => semanticWrite(
          hints: const <AfterCommitHint>[
            AfterCommitHint(
              kind: 'projection',
              entityType: 'task',
              entityId: 'e1',
            ),
          ],
        ),
      );
      h.hintHandler.received.clear();
      await h.bus.execute(
        cmd,
        (TransactionSession session) async => semanticWrite(),
      );
      expect(h.hintHandler.received, isEmpty);
    });
  });
}
