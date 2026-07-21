import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/application/focus_resume_reconciler.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_time_policy.dart';

import 'focus_test_support.dart';

/// Task 7.5 lifecycle recovery: on app launch/resume the open focus session is
/// reconciled from persisted timer truth against a fresh clock reading, exactly
/// as reminders reconcile on the R-NOTIFY-004 lifecycle triggers. History is
/// never rewritten; an ambiguous reboot delta is surfaced for user correction
/// rather than fabricated (R-FOCUS-002).
///
/// **Validates: Requirements R-FOCUS-002, R-FOCUS-003, R-NOTIFY-004**
///
/// Evidence: [TEST-DB-FOCUS-RESUME][MVP][TASK-7.5]
void main() {
  late FocusHarness h;
  late FocusResumeReconciler reconciler;

  setUp(() async {
    h = await FocusHarness.open(initialUtc: DateTime.utc(2024, 6, 1, 9));
    reconciler = FocusResumeReconciler(
      repository: h.reads,
      clock: h.clock,
      monotonicClock: h.monotonic,
    );
  });

  tearDown(() async {
    await h.close();
  });

  Future<String> startCountUp() => h.start(
    input: StartFocusSessionInput(
      lifeAreaId: h.lifeAreaId.value,
      mode: FocusMode.countUp,
    ),
    seed: 'start',
  );

  test('no open session reconciles to nothing', () async {
    final FocusResumeReport report = await reconciler.reconcileOnResume(
      h.profileId,
    );
    expect(report.hadOpenSession, isFalse);
    expect(report.needsUserCorrection, isFalse);
  });

  test('same-boot resume uses the monotonic clock as authoritative', () async {
    final String sessionId = await startCountUp();
    // 25 minutes pass with no reboot: monotonic is authoritative.
    h.clock.advance(const Duration(minutes: 25));
    h.monotonic.advance(const Duration(minutes: 25));

    final FocusResumeReport report = await reconciler.reconcileOnResume(
      h.profileId,
    );
    expect(report.hadOpenSession, isTrue);
    expect(report.sessionId, sessionId);
    expect(report.statusWire, 'running');
    expect(report.needsUserCorrection, isFalse);
    expect(report.resolution, isA<ElapsedKnown>());
    expect(
      (report.resolution! as ElapsedKnown).source,
      ElapsedSource.monotonic,
    );
    expect(report.liveElapsed, const Duration(minutes: 25));
  });

  test(
    'reboot with a plausible wall delta falls back to bounded wall time',
    () async {
      await startCountUp();
      // The device reboots after 30 minutes of wall time elapse.
      h.clock.advance(const Duration(minutes: 30));
      h.monotonic.reboot(newBootId: 'boot-2');

      final FocusResumeReport report = await reconciler.reconcileOnResume(
        h.profileId,
        maxPlausibleSegment: const Duration(hours: 12),
      );
      expect(report.hadOpenSession, isTrue);
      expect(report.needsUserCorrection, isFalse);
      expect(report.resolution, isA<ElapsedKnown>());
      expect(
        (report.resolution! as ElapsedKnown).source,
        ElapsedSource.wallClock,
      );
      expect(report.liveElapsed, const Duration(minutes: 30));
    },
  );

  test(
    'reboot with an implausible wall delta is surfaced for correction',
    () async {
      await startCountUp();
      // A huge wall jump after reboot exceeds the plausibility bound.
      h.clock.advance(const Duration(hours: 40));
      h.monotonic.reboot(newBootId: 'boot-2');

      final FocusResumeReport report = await reconciler.reconcileOnResume(
        h.profileId,
        maxPlausibleSegment: const Duration(hours: 12),
      );
      expect(report.hadOpenSession, isTrue);
      expect(report.needsUserCorrection, isTrue);
      expect(report.resolution, isA<ElapsedAmbiguous>());
      // The floor is the accumulated work plus the bound, never a fabricated
      // 40-hour segment.
      expect(report.liveElapsed, const Duration(hours: 12));
    },
  );

  test('a paused session reconciles to its durable accumulated work', () async {
    final String sessionId = await startCountUp();
    // Work 15 minutes, then pause.
    h.clock.advance(const Duration(minutes: 15));
    h.monotonic.advance(const Duration(minutes: 15));
    h.expectSuccess(
      await h.service.pause(
        commandId: h.nextCommandId('pause'),
        profileId: h.profileId,
        input: PauseFocusSessionInput(sessionId: sessionId),
      ),
    );
    // Time passes while paused; the paused elapsed must not grow.
    h.clock.advance(const Duration(minutes: 45));
    h.monotonic.advance(const Duration(minutes: 45));

    final FocusResumeReport report = await reconciler.reconcileOnResume(
      h.profileId,
    );
    expect(report.hadOpenSession, isTrue);
    expect(report.statusWire, 'paused');
    expect(report.needsUserCorrection, isFalse);
    expect(report.liveElapsed, const Duration(minutes: 15));
  });
}
