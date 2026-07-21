/// Sync status surface (R-SYNC-005): pending, last success, current error,
/// conflicts, retention/epoch reset, and manual retry availability.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_state.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-STATE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-005')],
);

void main() {
  group('SyncStatus', () {
    testWithEvidence(
      _evidence('SIGNED-OUT-INERT'),
      'signed out status is inert and never offers retry',
      () {
        final SyncStatus status = SyncStatus.signedOut();
        expect(status.linkState, SyncLinkState.signedOut);
        expect(status.canRetry, isFalse);
        expect(status.requiresReset, isFalse);
        expect(status.hasPending, isFalse);
      },
    );

    testWithEvidence(
      _evidence('RETRY-WHEN-LINKED-WITH-ERROR'),
      'a linked account with a network error can retry',
      () {
        const SyncStatus status = SyncStatus(
          linkState: SyncLinkState.linked,
          pendingOperationCount: 3,
          openConflictCount: 0,
          error: SyncErrorKind.network,
          currentErrorCode: 'sync.network',
        );
        expect(status.canRetry, isTrue);
        expect(status.hasPending, isTrue);
      },
    );

    testWithEvidence(
      _evidence('RESET-BLOCKS-RETRY'),
      'a retention/epoch reset requires bootstrap and suppresses plain retry',
      () {
        const SyncStatus status = SyncStatus(
          linkState: SyncLinkState.linked,
          pendingOperationCount: 5,
          openConflictCount: 0,
          error: SyncErrorKind.retentionOrEpochReset,
        );
        expect(status.requiresReset, isTrue);
        expect(status.canRetry, isFalse);
      },
    );

    testWithEvidence(
      _evidence('CONFLICTS-VISIBLE'),
      'open conflicts are surfaced without blocking',
      () {
        const SyncStatus status = SyncStatus(
          linkState: SyncLinkState.linked,
          pendingOperationCount: 0,
          openConflictCount: 2,
          error: SyncErrorKind.none,
        );
        expect(status.hasConflicts, isTrue);
        // No error and no pending work: nothing to retry.
        expect(status.canRetry, isFalse);
      },
    );

    testWithEvidence(
      _evidence('LAST-SUCCESS-TRACKED'),
      'last success timestamp is carried through copyWith',
      () {
        final SyncStatus status = SyncStatus.signedOut().copyWith(
          linkState: SyncLinkState.linked,
          lastSuccessAtUtcMicros: 123456,
        );
        expect(status.lastSuccessAtUtcMicros, 123456);
        expect(status.linkState, SyncLinkState.linked);
      },
    );
  });
}
