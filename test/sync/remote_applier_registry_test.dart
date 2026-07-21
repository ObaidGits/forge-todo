/// Typed remote-applier registry (R-SYNC-003, design.md §8/§9).
///
/// The registry routes each inbound change to the one applier that owns its
/// entity type, applies a page in the given (parent-before-child) order, rejects
/// duplicate registrations, and aborts a page containing an unknown type rather
/// than applying it partially.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/database_harness.dart';
import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-APPLIER-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-003')],
);

final class _RecordingApplier implements RemoteApplier {
  _RecordingApplier(this.entityType, this.log);

  @override
  final String entityType;
  final List<String> log;

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    log.add('$entityType:${change.entityId}');
  }
}

TransactionSession _session() => HarnessTransactionSession(
  repositories: HarnessRepositorySet(const <Type, Object>{}),
  origin: WriteOrigin.remoteApply,
  commitSeq: 1,
);

RemoteChange _change(String type, String id, {String? parent}) => RemoteChange(
  changeId: 'c-$type-$id',
  entityType: type,
  entityId: id,
  kind: SyncOperationKind.insert,
  serverSeq: ServerSeq(1),
  serverVersion: 1,
  payload: const <String, Object?>{},
  parentEntityId: parent,
);

void main() {
  group('RemoteApplierRegistry', () {
    testWithEvidence(
      _evidence('DUPLICATE-REJECTED'),
      'two appliers for the same entity type are rejected',
      () {
        final List<String> log = <String>[];
        expect(
          () => RemoteApplierRegistry(<RemoteApplier>[
            _RecordingApplier('task', log),
            _RecordingApplier('task', log),
          ]),
          throwsA(isA<RemoteApplierException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('ROUTES-IN-ORDER'),
      'applyAll routes each change to its owning applier in page order',
      () async {
        final List<String> log = <String>[];
        final RemoteApplierRegistry registry = RemoteApplierRegistry(
          <RemoteApplier>[
            _RecordingApplier('goal', log),
            _RecordingApplier('roadmap', log),
          ],
        );
        await registry.applyAll(_session(), <RemoteChange>[
          _change('goal', 'g1'),
          _change('roadmap', 'r1', parent: 'g1'),
          _change('goal', 'g2'),
        ]);
        expect(log, <String>['goal:g1', 'roadmap:r1', 'goal:g2']);
      },
    );

    testWithEvidence(
      _evidence('UNKNOWN-TYPE-ABORTS'),
      'a change with no registered applier aborts the page',
      () async {
        final List<String> log = <String>[];
        final RemoteApplierRegistry registry = RemoteApplierRegistry(
          <RemoteApplier>[_RecordingApplier('goal', log)],
        );
        await expectLater(
          registry.applyAll(_session(), <RemoteChange>[
            _change('goal', 'g1'),
            _change('unknown_type', 'x1'),
          ]),
          throwsA(isA<RemoteApplierException>()),
        );
        // The first (known) change did run before the abort; the aborting
        // transaction (task 9.7) is what makes the whole page atomic.
        expect(log, <String>['goal:g1']);
      },
    );

    testWithEvidence(
      _evidence('ENTITY-TYPES-SORTED'),
      'registered entity types are reported sorted for deterministic iteration',
      () {
        final List<String> log = <String>[];
        final RemoteApplierRegistry registry =
            RemoteApplierRegistry(<RemoteApplier>[
              _RecordingApplier('task', log),
              _RecordingApplier('goal', log),
              _RecordingApplier('note', log),
            ]);
        expect(registry.entityTypes, <String>['goal', 'note', 'task']);
        expect(registry.supports('goal'), isTrue);
        expect(registry.supports('missing'), isFalse);
      },
    );
  });
}
