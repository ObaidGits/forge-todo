import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix, String requirement) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('TEST-REL-HARNESS-$suffix'),
      releaseTag: ReleaseTag.mvp,
      taskId: SpecTaskId('2.6'),
      requirements: <RequirementId>[RequirementId(requirement)],
    );

final class _DiskFullException implements Exception {
  const _DiskFullException();
}

void main() {
  testWithEvidence(
    _evidence('001', 'NFR-REL-004'),
    'unit of work commits sequence and expires transaction repositories',
    () async {
      final TransactionalTestStore store = TransactionalTestStore();
      final FakeUnitOfWork unitOfWork = FakeUnitOfWork(
        repositories: <Type, Object>{TransactionalTestStore: store},
        participants: <TransactionalParticipant>[store],
      );
      late RepositorySet scopedRepositories;

      final String result = await unitOfWork.transaction<String>((
        TransactionSession session,
      ) async {
        scopedRepositories = session.repositories;
        expect(session.commitSeq, 1);
        expect(session.origin, WriteOrigin.remoteApply);
        session.repositories.resolve<TransactionalTestStore>()['value'] = 7;
        return 'committed';
      }, origin: WriteOrigin.remoteApply);

      expect(result, 'committed');
      expect(unitOfWork.committedSequence, 1);
      expect(store['value'], 7);
      expect(
        () => scopedRepositories.resolve<TransactionalTestStore>(),
        throwsStateError,
      );
    },
  );

  testWithEvidence(
    _evidence('002', 'NFR-REL-004'),
    'failed transaction restores participants and does not advance sequence',
    () async {
      final TransactionalTestStore store = TransactionalTestStore();
      store['value'] = 'before';
      final FakeUnitOfWork unitOfWork = FakeUnitOfWork(
        repositories: <Type, Object>{TransactionalTestStore: store},
        participants: <TransactionalParticipant>[store],
      );

      unitOfWork.failNextCommit(const _DiskFullException());
      await expectLater(
        unitOfWork.transaction<void>((TransactionSession session) async {
          session.repositories.resolve<TransactionalTestStore>()['value'] =
              'partial';
        }),
        throwsA(isA<_DiskFullException>()),
      );

      expect(store['value'], 'before');
      expect(unitOfWork.committedSequence, 0);
    },
  );

  testWithEvidence(
    _evidence('003', 'NFR-REL-003'),
    'scripted transport records requests and exposes partial network failure',
    () async {
      final FakeTransport<String, String> transport =
          FakeTransport<String, String>(<TransportStep<String>>[
            const TransportStep<String>.response('accepted'),
            const TransportStep<String>.failure(
              TransportFailure(TransportFailureKind.connectionLostAfterCommit),
            ),
          ]);

      expect(await transport.send('push-1'), 'accepted');
      await expectLater(
        transport.send('push-2'),
        throwsA(
          isA<TransportFailure>().having(
            (TransportFailure failure) => failure.kind,
            'kind',
            TransportFailureKind.connectionLostAfterCommit,
          ),
        ),
      );
      expect(transport.requests, <String>['push-1', 'push-2']);
      transport.verifyExhausted();
    },
  );

  testWithEvidence(
    _evidence('004', 'NFR-REL-004'),
    'database runtime and factory expose deterministic lifecycle ownership',
    () async {
      FakeDatabaseRuntime createRuntime() => FakeDatabaseRuntime(
        activeGeneration: DatabaseGeneration(
          id: GenerationId('generation_test_001'),
          schemaVersion: 1,
        ),
        unitOfWork: FakeUnitOfWork(repositories: <Type, Object>{}),
      );

      final FakeDatabaseRuntimeFactory factory = FakeDatabaseRuntimeFactory(
        createRuntime,
      );
      final FakeDatabaseRuntime runtime = await factory.open();
      runtime.enterMaintenance();
      expect(runtime.state, DatabaseRuntimeState.maintenance);
      runtime.resume();
      expect(runtime.state, DatabaseRuntimeState.ready);
      await runtime.dispose();
      await runtime.dispose();
      expect(runtime.state, DatabaseRuntimeState.closed);
      expect(factory.openCount, 1);
    },
  );
}
