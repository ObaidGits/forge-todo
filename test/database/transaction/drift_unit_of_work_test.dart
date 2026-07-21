import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_guard.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/application/unit_of_work.dart';

import 'command_test_support.dart';

/// Transaction-scoped repository, nested join/fail, guard, and commit-sequence
/// behavior over a real Drift database.
///
/// **Validates: Requirements R-GEN-005, R-SYNC-002**
void main() {
  late CommandHarness h;

  setUp(() async {
    h = await CommandHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given a transaction-scoped repository', () {
    test('when used after commit then it throws', () async {
      late ActivityRepository leaked;
      await h.unitOfWork.transaction((TransactionSession session) async {
        leaked = session.repositories.resolve<ActivityRepository>();
      });
      expect(
        () => leaked.append(
          id: 'a',
          profileId: h.profileId.value,
          eventType: 'x',
          entityType: 'task',
          entityId: 'e',
          occurredAtUtc: 0,
          payloadVersion: 1,
          commitSeq: 1,
        ),
        throwsA(isA<TransactionClosedError>()),
      );
    });

    test('when resolving inside the transaction then it caches one '
        'instance', () async {
      await h.unitOfWork.transaction((TransactionSession session) async {
        final ActivityRepository a = session.repositories
            .resolve<ActivityRepository>();
        final ActivityRepository b = session.repositories
            .resolve<ActivityRepository>();
        expect(identical(a, b), isTrue);
      });
    });

    test('when resolving an unregistered type then it throws', () async {
      await h.unitOfWork.transaction((TransactionSession session) async {
        expect(
          () => session.repositories.resolve<_Unregistered>(),
          throwsA(isA<StateError>()),
        );
      });
    });
  });

  group('given a nested transaction', () {
    test('when the origin matches then it joins the same session', () async {
      await h.unitOfWork.transaction((TransactionSession outer) async {
        await h.unitOfWork.transaction((TransactionSession inner) async {
          expect(identical(inner, outer), isTrue);
          expect(inner.commitSeq, outer.commitSeq);
        });
      });
    });

    test('when a different origin is requested then it fails '
        'deterministically', () async {
      await expectLater(
        h.unitOfWork.transaction((TransactionSession outer) async {
          await h.unitOfWork.transaction(
            origin: WriteOrigin.remoteApply,
            (TransactionSession inner) async {},
          );
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('when the inner action throws then the whole transaction rolls '
        'back', () async {
      await expectLater(
        h.unitOfWork.transaction((TransactionSession outer) async {
          await outer.repositories.resolve<ActivityRepository>().append(
            id: 'a1',
            profileId: h.profileId.value,
            eventType: 'x',
            entityType: 'task',
            entityId: 'e',
            occurredAtUtc: 0,
            payloadVersion: 1,
            commitSeq: outer.commitSeq,
          );
          await h.unitOfWork.transaction((TransactionSession inner) async {
            throw StateError('inner failure');
          });
        }),
        throwsA(isA<StateError>()),
      );
      expect(await h.scalarInt('SELECT COUNT(*) AS n FROM activity_events'), 0);
    });
  });

  group('given the in-transaction guard', () {
    test('when the body awaits a timer then it is forbidden', () async {
      await expectLater(
        h.unitOfWork.transaction((TransactionSession session) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }),
        throwsA(isA<ForbiddenInTransaction>()),
      );
    });

    test('when the body awaits a microtask then it is allowed', () async {
      final int seq = await h.unitOfWork.transaction((
        TransactionSession session,
      ) async {
        await Future<void>.microtask(() {});
        return session.commitSeq;
      });
      expect(seq, greaterThan(0));
    });
  });

  group('given the commit sequence', () {
    test('when writes commit sequentially then it increases '
        'monotonically', () async {
      final List<int> seen = <int>[];
      for (int i = 0; i < 5; i += 1) {
        final int seq = await h.bus
            .execute(
              command(profileId: h.profileId, id: 'cmd-$i', requestHash: 'h$i'),
              (TransactionSession session) async => semanticWrite(
                entityId: 'e$i',
                groupId: 'g$i',
                operationId: 'op$i',
                activityId: 'a$i',
              ),
            )
            .then((r) => r.valueOrNull!.commitSeq);
        seen.add(seq);
      }
      expect(seen, <int>[1, 2, 3, 4, 5]);
    });
  });
}

final class _Unregistered {}
