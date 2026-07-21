/// The shared server wire vocabulary and limits stay protocol-compatible with
/// the client contracts and the PostgreSQL backend (task 9.2; R-SYNC-003,
/// R-SYNC-004, NFR-SEC-002).
///
/// The SQL side of these invariants is asserted database-free by
/// tool/sync_server_lint.py; this test locks the Dart source of truth so the
/// two ends cannot silently drift.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/application/sync_server_contract.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix, String requirement) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('TEST-SYNC-SERVER-CONTRACT-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('9.2'),
      requirements: <RequirementId>[RequirementId(requirement)],
    );

void main() {
  group('group outcome wire vocabulary', () {
    testWithEvidence(
      _evidence('OUTCOME-ROUNDTRIP', 'R-SYNC-003'),
      'every outcome round-trips through its wire string',
      () {
        for (final SemanticGroupOutcome outcome
            in SemanticGroupOutcome.values) {
          final String wire = SyncGroupOutcomeWire.of(outcome);
          expect(SyncGroupOutcomeWire.fromWire(wire), outcome);
        }
      },
    );

    testWithEvidence(
      _evidence('OUTCOME-STALE-SPELLING', 'R-SYNC-003'),
      'stale epoch spells as stale_epoch on the wire',
      () {
        expect(
          SyncGroupOutcomeWire.of(SemanticGroupOutcome.staleEpoch),
          'stale_epoch',
        );
      },
    );

    testWithEvidence(
      _evidence('OUTCOME-REJECTS-UNKNOWN', 'R-SYNC-003'),
      'an unknown outcome string is rejected rather than silently misread',
      () {
        expect(
          () => SyncGroupOutcomeWire.fromWire('mangled'),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('OUTCOME-COMPLETE', 'R-SYNC-003'),
      'the wire list covers exactly the outcome enum',
      () {
        expect(
          SyncGroupOutcomeWire.all.toSet(),
          SemanticGroupOutcome.values.map(SyncGroupOutcomeWire.of).toSet(),
        );
        expect(
          SyncGroupOutcomeWire.all.length,
          SemanticGroupOutcome.values.length,
        );
      },
    );
  });

  group('operation kind wire vocabulary', () {
    testWithEvidence(
      _evidence('KIND-MIRRORS-DOMAIN', 'R-SYNC-003'),
      'operation kind strings mirror SyncOperationKind.wire',
      () {
        expect(
          SyncOperationKindWire.all.toSet(),
          SyncOperationKind.values.map((SyncOperationKind k) => k.wire).toSet(),
        );
        for (final String wire in SyncOperationKindWire.all) {
          expect(SyncOperationKind.fromWire(wire).wire, wire);
        }
      },
    );
  });

  group('RPC surface', () {
    testWithEvidence(
      _evidence('RPC-NAMES', 'NFR-SEC-002'),
      'the only write path names are forge.push and forge.pull',
      () {
        expect(SyncServerRpc.all, <String>['forge.push', 'forge.pull']);
        expect(SyncServerRpc.push, 'forge.push');
        expect(SyncServerRpc.pull, 'forge.pull');
      },
    );
  });

  group('protocol limits', () {
    testWithEvidence(
      _evidence('LIMITS-POSITIVE', 'R-SYNC-004'),
      'limits are positive and internally consistent',
      () {
        expect(SyncProtocolLimits.maxGroupsPerPush, greaterThan(0));
        expect(SyncProtocolLimits.maxOperationsPerGroup, greaterThan(0));
        expect(SyncProtocolLimits.maxChangesPerPullPage, greaterThan(0));
        expect(SyncProtocolLimits.maxOperationPayloadBytes, greaterThan(0));
        expect(SyncProtocolLimits.maxPushRequestBytes, greaterThan(0));
        // A whole batch cannot admit fewer operations than a single full group.
        expect(
          SyncProtocolLimits.maxOperationsPerPush,
          greaterThanOrEqualTo(SyncProtocolLimits.maxOperationsPerGroup),
        );
        expect(SyncProtocolLimits.protocolVersion, kSyncProtocolVersion);
      },
    );
  });
}
