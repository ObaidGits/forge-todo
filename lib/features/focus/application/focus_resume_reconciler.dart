import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/domain/focus_repository.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';
import 'package:forge/features/focus/domain/focus_time_policy.dart';

/// The outcome of reconciling any open focus session on app launch/resume
/// (R-FOCUS-002, R-NOTIFY-004 lifecycle trigger parity).
///
/// The reconciler is a pure read + policy orchestration: it never rewrites
/// history. When the resolved current segment is ambiguous (a reboot with an
/// implausible or backwards wall delta), [needsUserCorrection] is set so the
/// presentation layer can prompt for an explicit correction rather than record
/// a fabricated duration (R-FOCUS-002). When it is known, [liveElapsed] carries
/// the reconstructed live elapsed time (accumulated work + current segment).
final class FocusResumeReport {
  const FocusResumeReport._({
    required this.hadOpenSession,
    this.sessionId,
    this.statusWire,
    this.resolution,
    this.liveElapsed,
  });

  /// No open session existed; nothing to reconcile.
  const FocusResumeReport.none() : this._(hadOpenSession: false);

  /// An open session was reconciled to [resolution].
  const FocusResumeReport.reconciled({
    required String sessionId,
    required String statusWire,
    required ElapsedResolution resolution,
    required Duration liveElapsed,
  }) : this._(
         hadOpenSession: true,
         sessionId: sessionId,
         statusWire: statusWire,
         resolution: resolution,
         liveElapsed: liveElapsed,
       );

  /// Whether an open (running or paused) session was found.
  final bool hadOpenSession;

  /// The reconciled session id, or null when none was open.
  final String? sessionId;

  /// The open session's visible status wire value (`running`/`paused`), or null.
  final String? statusWire;

  /// The resolved current-segment outcome, or null when none was open.
  final ElapsedResolution? resolution;

  /// The reconstructed live elapsed time (accumulated + current segment). For an
  /// ambiguous resolution this is the accumulated work plus the segment lower
  /// bound (a floor), never a fabricated value.
  final Duration? liveElapsed;

  /// True when the resolution is ambiguous and the user must confirm a
  /// correction before any duration is recorded (R-FOCUS-002).
  bool get needsUserCorrection => resolution is ElapsedAmbiguous;
}

/// Reconciles the single open focus session when the app launches or resumes
/// (R-FOCUS-002).
///
/// A running focus session persists anchored timer truth rather than a ticking
/// value, so after process death or reboot the live elapsed time must be
/// reconstructed from a fresh clock reading. This service loads the open
/// session through the focus read port, takes one live [Clock]/[MonotonicClock]
/// reading, and delegates to the pure [FocusTimePolicy]. It depends only on the
/// focus domain (a repository port and the policy) and the core clocks, so it is
/// fully testable with fakes and performs no I/O beyond the port read.
final class FocusResumeReconciler {
  const FocusResumeReconciler({
    required this.repository,
    required this.clock,
    required this.monotonicClock,
  });

  final FocusRepository repository;
  final Clock clock;
  final MonotonicClock monotonicClock;

  /// Reconciles the open session for [profileId] against the current clocks.
  ///
  /// [maxPlausibleSegment] bounds the wall-clock fallback after a boot change:
  /// a segment longer than it is treated as ambiguous and surfaced for user
  /// correction. It is ignored while the boot id matches because the monotonic
  /// clock is authoritative there (R-FOCUS-002).
  Future<FocusResumeReport> reconcileOnResume(
    ProfileId profileId, {
    Duration? maxPlausibleSegment,
  }) async {
    final FocusSession? session = await repository.openSession(profileId);
    if (session == null) {
      return const FocusResumeReport.none();
    }

    // A paused session has no running segment to reconcile: its accumulated
    // work is already durable and the elapsed time is exactly that.
    if (session.status == FocusSessionStatus.paused) {
      return FocusResumeReport.reconciled(
        sessionId: session.id.value,
        statusWire: session.status.wire,
        resolution: const ElapsedKnown(
          segment: Duration.zero,
          source: ElapsedSource.monotonic,
        ),
        liveElapsed: Duration(seconds: session.accumulatedDurationSec),
      );
    }

    final TimerReading now = TimerReading(
      bootSessionId: monotonicClock.bootSessionId(),
      monotonic: monotonicClock.now().elapsedSinceBoot,
      wallUtcMicros: clock.utcNow().microsecondsSinceEpoch,
    );
    final ElapsedResolution resolution = FocusTimePolicy.resolveSegment(
      session.timerTruth,
      now,
      maxPlausibleSegment: maxPlausibleSegment,
    );
    final Duration liveElapsed = FocusTimePolicy.liveElapsed(
      Duration(seconds: session.accumulatedDurationSec),
      resolution,
    );
    return FocusResumeReport.reconciled(
      sessionId: session.id.value,
      statusWire: session.status.wire,
      resolution: resolution,
      liveElapsed: liveElapsed,
    );
  }
}
