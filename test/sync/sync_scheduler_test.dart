/// Sync scheduling/orchestration (R-SYNC-005, design.md §14).
///
/// Unit examples plus generative property tests for the four trigger families
/// (manual, lifecycle, debounced, opportunistic), data-saver deferral,
/// full-jitter backoff gating, and the realtime hint as a non-authoritative
/// pull prompt that never bypasses the ordered pull.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/application/sync_scheduler.dart';
import 'package:forge/features/sync/domain/sync_backoff.dart';
import 'package:forge/features/sync/domain/sync_connectivity.dart';
import 'package:forge/features/sync/domain/sync_trigger.dart';

import '../helpers/evidence.dart';
import '../helpers/fake_clock.dart';
import '../helpers/fake_jitter_entropy.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-SCHED-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.6'),
  requirements: <RequirementId>[RequirementId('R-SYNC-005')],
);

const SyncEnvironment _online = SyncEnvironment(
  connectivity: Connectivity.unmetered,
);
const SyncEnvironment _meteredSaver = SyncEnvironment(
  connectivity: Connectivity.metered,
  dataSaverEnabled: true,
);

FullJitterBackoff _backoff() => FullJitterBackoff(
  base: const Duration(seconds: 1),
  cap: const Duration(seconds: 30),
);

SyncScheduler _scheduler({
  FakeMonotonicClock? clock,
  JitterEntropy? entropy,
  Duration debounceWindow = const Duration(seconds: 2),
  SyncEnvironment environment = _online,
}) => SyncScheduler(
  clock: clock ?? FakeMonotonicClock(),
  backoff: _backoff(),
  entropy: entropy ?? SeededJitterEntropy(1),
  debounceWindow: debounceWindow,
  environment: environment,
);

void main() {
  group('Debounced local edits', () {
    testWithEvidence(
      _evidence('PROP-DEBOUNCE-COALESCES'),
      'a burst of local edits within the window collapses into exactly one '
      'scheduled push',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final FakeMonotonicClock clock = FakeMonotonicClock();
          const Duration window = Duration(seconds: 2);
          final SyncScheduler scheduler = _scheduler(
            clock: clock,
            debounceWindow: window,
          );

          final int edits = 1 + rng.nextInt(8);
          // First edit anchors the debounce window at t0.
          scheduler.noteLocalEdit();
          final int dueAt =
              clock.now().elapsedSinceBoot.inMicroseconds +
              window.inMicroseconds;
          for (int i = 1; i < edits; i += 1) {
            // Subsequent edits land strictly inside the window.
            clock.advance(Duration(milliseconds: 1 + rng.nextInt(200)));
            if (clock.now().elapsedSinceBoot.inMicroseconds >= dueAt) {
              break;
            }
            scheduler.noteLocalEdit();
          }

          // Before the window elapses nothing is due.
          expect(
            scheduler.pollDueWork(),
            SyncWorkKind.none,
            reason: 'fired early seed=$seed',
          );
          expect(scheduler.nextWakeMicros(), dueAt);

          // At the window boundary exactly one push is emitted.
          clock.advance(window);
          expect(
            scheduler.pollDueWork(),
            SyncWorkKind.push,
            reason: 'no push at boundary seed=$seed',
          );
          scheduler.onSyncSucceeded();

          // The burst produced a single sync; nothing remains.
          expect(
            scheduler.pollDueWork(),
            SyncWorkKind.none,
            reason: 'duplicate push seed=$seed',
          );
          expect(scheduler.nextWakeMicros(), isNull);
        }
      },
    );

    testWithEvidence(
      _evidence('DEBOUNCE-WINDOW-ANCHORED-AT-FIRST-EDIT'),
      'the debounce deadline is anchored at the first edit and not reset by '
      'later edits in the burst',
      () {
        final FakeMonotonicClock clock = FakeMonotonicClock();
        final SyncScheduler scheduler = _scheduler(
          clock: clock,
          debounceWindow: const Duration(seconds: 2),
        );
        scheduler.noteLocalEdit();
        final int? firstDue = scheduler.nextWakeMicros();
        clock.advance(const Duration(milliseconds: 500));
        scheduler.noteLocalEdit();
        expect(scheduler.nextWakeMicros(), firstDue);
      },
    );
  });

  group('Manual trigger', () {
    testWithEvidence(
      _evidence('MANUAL-RUNS-IMMEDIATELY'),
      'a manual trigger schedules push-and-pull immediately with no debounce',
      () {
        final SyncScheduler scheduler = _scheduler();
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('MANUAL-BYPASSES-DATA-SAVER'),
      'a manual trigger runs even under data-saver on a metered link',
      () {
        final SyncScheduler scheduler = _scheduler(environment: _meteredSaver);
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('MANUAL-CLEARS-BACKOFF'),
      'a manual retry clears the failure backoff gate and runs now',
      () {
        final FakeMonotonicClock clock = FakeMonotonicClock();
        final SyncScheduler scheduler = _scheduler(
          clock: clock,
          entropy: const MaxJitterEntropy(),
        );
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
        scheduler.onSyncFailed();
        expect(scheduler.isBackingOff(), isTrue);
        // A user-initiated retry ignores the backoff gate.
        scheduler.requestManualSync();
        expect(scheduler.isBackingOff(), isFalse);
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
        expect(scheduler.consecutiveFailures, 0);
      },
    );
  });

  group('Lifecycle triggers', () {
    testWithEvidence(
      _evidence('LAUNCH-RECONCILES'),
      'app launch schedules a push-and-pull reconcile',
      () {
        final SyncScheduler scheduler = _scheduler();
        scheduler.trigger(SyncTriggerSource.appLaunch);
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('BACKGROUND-FLUSH-DEFERS-UNDER-DATA-SAVER'),
      'a background flush is deferred under data-saver but a resume reconcile '
      'is not',
      () {
        final SyncScheduler scheduler = _scheduler(environment: _meteredSaver);
        scheduler.trigger(SyncTriggerSource.appBackground);
        expect(
          scheduler.pollDueWork(),
          SyncWorkKind.none,
          reason: 'background flush should defer under data-saver',
        );
        scheduler.trigger(SyncTriggerSource.appResume);
        expect(
          scheduler.pollDueWork(),
          SyncWorkKind.pushAndPull,
          reason: 'foreground resume should not defer',
        );
      },
    );
  });

  group('Opportunistic and connectivity', () {
    testWithEvidence(
      _evidence('OFFLINE-HOLDS-WORK'),
      'nothing runs while offline; regaining connectivity releases the work',
      () {
        final SyncScheduler scheduler = _scheduler(
          environment: SyncEnvironment.unknown,
        );
        scheduler.trigger(SyncTriggerSource.idle);
        expect(scheduler.pollDueWork(), SyncWorkKind.none);
        scheduler.updateEnvironment(_online);
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('CONNECTIVITY-REGAIN-CLEARS-BACKOFF'),
      'regaining connectivity clears the backoff gate',
      () {
        final FakeMonotonicClock clock = FakeMonotonicClock();
        final SyncScheduler scheduler = _scheduler(
          clock: clock,
          entropy: const MaxJitterEntropy(),
        );
        scheduler.trigger(SyncTriggerSource.idle);
        scheduler.pollDueWork();
        scheduler.onSyncFailed();
        expect(scheduler.isBackingOff(), isTrue);
        // Drop offline, then regain connectivity: the gate is cleared.
        scheduler.updateEnvironment(SyncEnvironment.unknown);
        scheduler.updateEnvironment(_online);
        expect(scheduler.isBackingOff(), isFalse);
      },
    );

    testWithEvidence(
      _evidence('DATA-SAVER-DEFERS-OPPORTUNISTIC'),
      'idle opportunistic work defers under data-saver on a metered link',
      () {
        final SyncScheduler scheduler = _scheduler(environment: _meteredSaver);
        scheduler.trigger(SyncTriggerSource.idle);
        expect(scheduler.pollDueWork(), SyncWorkKind.none);
        // Turning data-saver off (or moving to unmetered) releases it.
        scheduler.updateEnvironment(_online);
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );
  });

  group('Realtime hint (non-authoritative)', () {
    testWithEvidence(
      _evidence('PROP-REALTIME-ONLY-PROMPTS-PULL'),
      'a realtime hint alone only ever schedules an ordered pull and never a '
      'push-only or empty-when-due attempt',
      () {
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          final SyncScheduler scheduler = _scheduler();
          final int hints = 1 + rng.nextInt(5);
          for (int i = 0; i < hints; i += 1) {
            scheduler.noteRealtimeHint();
          }
          // The authoritative path is always the ordered pull: a hint can only
          // ever yield a pull, never a push, and the multiple hints coalesce.
          expect(
            scheduler.pollDueWork(),
            SyncWorkKind.pull,
            reason: 'realtime hint bypassed ordered pull seed=$seed',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('REALTIME-MERGES-WITH-PENDING-PUSH'),
      'a realtime hint alongside pending local edits still pulls (ordered) and '
      'pushes',
      () {
        final FakeMonotonicClock clock = FakeMonotonicClock();
        final SyncScheduler scheduler = _scheduler(
          clock: clock,
          debounceWindow: const Duration(seconds: 2),
        );
        scheduler.noteLocalEdit();
        scheduler.noteRealtimeHint();
        // The realtime hint is immediate, so the merged work is due now.
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('REALTIME-OFFLINE-HOLDS'),
      'a realtime hint while offline does not pull until connectivity returns',
      () {
        final SyncScheduler scheduler = _scheduler(
          environment: SyncEnvironment.unknown,
        );
        scheduler.noteRealtimeHint();
        expect(scheduler.pollDueWork(), SyncWorkKind.none);
      },
    );
  });

  group('Backoff gating', () {
    testWithEvidence(
      _evidence('BACKOFF-HOLDS-THEN-RELEASES'),
      'a failure gates the retry until the jittered delay elapses',
      () {
        final FakeMonotonicClock clock = FakeMonotonicClock();
        final SyncScheduler scheduler = _scheduler(
          clock: clock,
          entropy: const MaxJitterEntropy(),
        );
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
        scheduler.onSyncFailed();

        // Max jitter at attempt 0 == base (1s). Just before the gate: nothing.
        clock.advance(const Duration(milliseconds: 999));
        expect(scheduler.pollDueWork(), SyncWorkKind.none);
        // At/after the gate the retry is due.
        clock.advance(const Duration(milliseconds: 1));
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );

    testWithEvidence(
      _evidence('ONE-ATTEMPT-AT-A-TIME'),
      'no new attempt is issued while one is in flight',
      () {
        final SyncScheduler scheduler = _scheduler();
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
        // In flight: a second poll and even a new trigger yield no attempt.
        scheduler.requestManualSync();
        expect(scheduler.pollDueWork(), SyncWorkKind.none);
        scheduler.onSyncSucceeded();
        // After completion the queued manual request runs.
        expect(scheduler.pollDueWork(), SyncWorkKind.pushAndPull);
      },
    );
  });
}
