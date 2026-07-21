/// Ordered pull-cursor behavior (R-SYNC-003, data-model.md §6).
///
/// A generative property test plus example anchors. The cursor defines a total
/// order over `(epoch, serverSeq)`, only advances monotonically within an
/// epoch, treats already-applied pages as duplicates, and routes gaps and epoch
/// changes to bootstrap.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-CURSOR-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-003')],
);

SyncCursor _cursor(int epoch, int seq) =>
    SyncCursor(epoch: SnapshotEpoch(epoch), serverSeq: ServerSeq(seq));

void main() {
  group('SyncCursor ordering properties', () {
    testWithEvidence(
      _evidence('PROP-TOTAL-ORDER'),
      'compareTo is a consistent total order across epoch then serverSeq',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final SyncCursor a = _cursor(rng.nextInt(4), rng.nextInt(20));
          final SyncCursor b = _cursor(rng.nextInt(4), rng.nextInt(20));
          final int ab = a.compareTo(b);
          final int ba = b.compareTo(a);
          // Antisymmetry.
          expect(ab.sign, -ba.sign, reason: 'antisymmetry failed seed=$seed');
          // Consistency with lexicographic (epoch, seq).
          final int expected = a.epoch.value != b.epoch.value
              ? a.epoch.value.compareTo(b.epoch.value)
              : a.serverSeq.value.compareTo(b.serverSeq.value);
          expect(ab.sign, expected.sign, reason: 'order wrong seed=$seed');
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-CONTIGUOUS-ADVANCE'),
      'replaying contiguous same-epoch pages advances monotonically to the end',
      () {
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          SyncCursor cursor = SyncCursor.initial();
          // Reset onto a random working epoch.
          final int epoch = 1 + rng.nextInt(3);
          cursor = cursor.resetToEpoch(SnapshotEpoch(epoch));
          int seq = 0;
          final int pages = rng.nextInt(8);
          for (int p = 0; p < pages; p += 1) {
            final int span = 1 + rng.nextInt(5);
            final ServerSeq from = ServerSeq(seq);
            final ServerSeq to = ServerSeq(seq + span);
            final CursorAdvanceDecision decision = cursor.decide(
              pageEpoch: SnapshotEpoch(epoch),
              fromSeq: from,
              toSeq: to,
            );
            expect(
              decision,
              CursorAdvanceDecision.apply,
              reason: 'contiguous page should apply seed=$seed page=$p',
            );
            final SyncCursor next = cursor.advanceTo(to);
            expect(
              next.serverSeq.value,
              greaterThanOrEqualTo(cursor.serverSeq.value),
              reason: 'cursor moved backward seed=$seed',
            );
            cursor = next;
            seq += span;
          }
          expect(cursor.serverSeq.value, seq);
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-REPLAY-IDEMPOTENT'),
      're-deciding an already-applied page is always a duplicate no-op',
      () {
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          final int epoch = 1 + rng.nextInt(3);
          final int at = 1 + rng.nextInt(20);
          final SyncCursor cursor = _cursor(epoch, at);
          // A page fully at or below the cursor within the same epoch.
          final int from = rng.nextInt(at);
          final int to = from + rng.nextInt(at - from + 1);
          final CursorAdvanceDecision decision = cursor.decide(
            pageEpoch: SnapshotEpoch(epoch),
            fromSeq: ServerSeq(from),
            toSeq: ServerSeq(to),
          );
          expect(
            decision,
            CursorAdvanceDecision.duplicate,
            reason: 'expected duplicate seed=$seed from=$from to=$to at=$at',
          );
        }
      },
    );
  });

  group('SyncCursor examples', () {
    testWithEvidence(
      _evidence('GAP-BOOTSTRAPS'),
      'a page that skips ahead of the cursor aborts to bootstrap',
      () {
        final SyncCursor cursor = _cursor(3, 10);
        expect(
          cursor.decide(
            pageEpoch: SnapshotEpoch(3),
            fromSeq: ServerSeq(12),
            toSeq: ServerSeq(15),
          ),
          CursorAdvanceDecision.bootstrap,
        );
      },
    );

    testWithEvidence(
      _evidence('NEWER-EPOCH-BOOTSTRAPS'),
      'a page from a newer epoch aborts to bootstrap rather than applying',
      () {
        final SyncCursor cursor = _cursor(3, 10);
        expect(
          cursor.decide(
            pageEpoch: SnapshotEpoch(4),
            fromSeq: ServerSeq(0),
            toSeq: ServerSeq(5),
          ),
          CursorAdvanceDecision.bootstrap,
        );
      },
    );

    testWithEvidence(
      _evidence('OLDER-EPOCH-BOOTSTRAPS'),
      'a page from a retired older epoch is stale and aborts to bootstrap',
      () {
        final SyncCursor cursor = _cursor(3, 10);
        expect(
          cursor.decide(
            pageEpoch: SnapshotEpoch(2),
            fromSeq: ServerSeq(10),
            toSeq: ServerSeq(12),
          ),
          CursorAdvanceDecision.bootstrap,
        );
      },
    );

    testWithEvidence(
      _evidence('NO-BACKWARD-ADVANCE'),
      'advancing to a lower sequence within an epoch is rejected',
      () {
        final SyncCursor cursor = _cursor(3, 10);
        expect(
          () => cursor.advanceTo(ServerSeq(9)),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('EPOCH-RESET-RESTARTS-SEQ'),
      'resetting onto a newer epoch restarts the sequence at zero',
      () {
        final SyncCursor cursor = _cursor(3, 10);
        final SyncCursor reset = cursor.resetToEpoch(SnapshotEpoch(4));
        expect(reset.epoch.value, 4);
        expect(reset.serverSeq.value, 0);
      },
    );
  });
}
