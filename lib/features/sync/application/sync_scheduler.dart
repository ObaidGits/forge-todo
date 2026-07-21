/// The client-side sync scheduling/orchestration layer (R-SYNC-005, design.md
/// §14). A pure, deterministic orchestrator over the transport, a monotonic
/// clock, a jitter entropy source, and a connectivity/data-saver environment —
/// all injected, all faked in tests, and none of which require a network.
///
/// The scheduler decides *whether* and *when* a sync attempt should run; it
/// does not itself open sockets or hold timers. The host drives it: it reports
/// triggers and environment changes, asks [nextWakeMicros] to arm one external
/// timer, calls [pollDueWork] when that timer fires (or on any trigger), runs
/// the returned work through the [SyncTransport], and reports the outcome back
/// via [onSyncSucceeded]/[onSyncFailed].
///
/// Scheduling never blocks local content and is only an acceleration surface.
///
/// Trigger semantics (see [SyncTriggerSource]):
/// * manual — user-initiated; runs immediately, clears any failure backoff, and
///   is never deferred by data-saver (R-SYNC-005 "manual retry").
/// * lifecycle (launch/resume/background) — a foreground reconcile runs
///   promptly; a background flush is deferrable under data-saver.
/// * debounced (localEdit) — a burst of local edits collapses into a single
///   scheduled push one debounce window after the first edit of the burst.
/// * opportunistic (idle/connectivityRegained) — runs when the environment has
///   spare capacity; regaining connectivity also clears the backoff gate.
/// * realtimeHint — a NON-AUTHORITATIVE hint that may prompt an ordered pull.
///   It carries no data (the method takes no payload), and it can only ever
///   contribute a `pull`; the authoritative path is always the ordered pull
///   through the cursor (data-model.md §6 "Realtime is only a pull hint").
library;

// Named constructor parameters cannot use private initializing formals
// (`this._field`), so the constructor assigns injected ports explicitly.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/core/domain/clock.dart';
import 'package:forge/features/sync/domain/sync_backoff.dart';
import 'package:forge/features/sync/domain/sync_connectivity.dart';
import 'package:forge/features/sync/domain/sync_trigger.dart';

/// The default debounce window used to coalesce a burst of local edits.
const Duration kDefaultDebounceWindow = Duration(seconds: 2);

/// A deterministic orchestrator for sync scheduling. Holds mutable scheduling
/// state but owns no OS resources (no timers, streams, or sockets); the host
/// supplies time through the injected [MonotonicClock].
final class SyncScheduler {
  SyncScheduler({
    required MonotonicClock clock,
    required FullJitterBackoff backoff,
    required JitterEntropy entropy,
    Duration debounceWindow = kDefaultDebounceWindow,
    SyncEnvironment environment = SyncEnvironment.unknown,
  }) : _clock = clock,
       _backoff = backoff,
       _entropy = entropy,
       _environment = environment,
       _debounceWindow = _requirePositive(debounceWindow);

  static Duration _requirePositive(Duration debounceWindow) {
    if (debounceWindow <= Duration.zero) {
      throw ArgumentError.value(
        debounceWindow,
        'debounceWindow',
        'Must be positive.',
      );
    }
    return debounceWindow;
  }

  final MonotonicClock _clock;
  final FullJitterBackoff _backoff;
  final JitterEntropy _entropy;
  final Duration _debounceWindow;

  SyncEnvironment _environment;

  /// The earliest monotonic instant (microseconds since boot) at which the
  /// currently scheduled work wants to run, or null when nothing is scheduled.
  int? _dueMicros;

  /// The merged work the next attempt should perform.
  SyncWorkKind _kind = SyncWorkKind.none;

  /// Whether the pending schedule may be deferred under a restricted
  /// environment. Any non-deferrable trigger (manual, reconcile, recovery)
  /// latches this to false until the next attempt runs.
  bool _deferrable = true;

  /// Consecutive failure count driving the full-jitter backoff.
  int _consecutiveFailures = 0;

  /// The monotonic instant before which a retry must not run, or null when no
  /// backoff gate is active.
  int? _backoffUntilMicros;

  /// Whether an attempt is currently running; only one runs at a time.
  bool _inFlight = false;

  int get _nowMicros => _clock.now().elapsedSinceBoot.inMicroseconds;

  /// The current environment snapshot.
  SyncEnvironment get environment => _environment;

  /// The number of consecutive failures currently held (0 when healthy).
  int get consecutiveFailures => _consecutiveFailures;

  /// Whether an attempt is in flight.
  bool get isInFlight => _inFlight;

  /// Whether any work is scheduled (regardless of whether it is due yet).
  bool get hasScheduledWork => _kind != SyncWorkKind.none && _dueMicros != null;

  /// Whether a failure backoff gate is currently holding retries back.
  bool isBackingOff() {
    final int? until = _backoffUntilMicros;
    return until != null && _nowMicros < until;
  }

  // --- Environment ---------------------------------------------------------

  /// Updates the observed connectivity/data-saver environment. Regaining
  /// connectivity (offline → online) is treated as a recovery trigger: it
  /// clears the backoff gate and schedules a prompt reconcile. The host should
  /// poll after calling this in case deferred work is now runnable.
  void updateEnvironment(SyncEnvironment environment) {
    final bool wasOffline = !_environment.isOnline;
    _environment = environment;
    if (wasOffline && environment.isOnline) {
      trigger(SyncTriggerSource.connectivityRegained);
    }
  }

  // --- Triggers ------------------------------------------------------------

  /// Records a sync request from [source] and (re)schedules work accordingly.
  void trigger(SyncTriggerSource source) {
    if (source.clearsBackoff) {
      _clearBackoff();
    }

    final SyncWorkKind requested = _workFor(source);
    _kind = mergeWorkKind(_kind, requested);
    if (!source.isDeferrableUnderDataSaver &&
        !source.isRealtimeHint &&
        !source.isDebounced) {
      // Manual, foreground reconcile, and recovery triggers must not be held
      // back by the data-saver policy.
      _deferrable = false;
    }

    final int now = _nowMicros;
    final int dueForSource = source.isDebounced
        ? now + _debounceWindow.inMicroseconds
        : now;
    _dueMicros = _earliest(_dueMicros, dueForSource);
  }

  /// Convenience for a user-initiated sync/retry (R-SYNC-005 "manual retry").
  void requestManualSync() => trigger(SyncTriggerSource.manual);

  /// Records that a local edit was committed. Bursts coalesce into one push a
  /// debounce window after the first edit of the burst.
  void noteLocalEdit() => trigger(SyncTriggerSource.localEdit);

  /// Records a NON-AUTHORITATIVE realtime hint. It carries no data and can only
  /// prompt an ordered pull; it never bypasses the authoritative cursor path.
  void noteRealtimeHint() => trigger(SyncTriggerSource.realtimeHint);

  // --- Polling and outcomes ------------------------------------------------

  /// Returns the work to run right now, or [SyncWorkKind.none] when nothing is
  /// due or runnable. When it returns runnable work it marks an attempt
  /// in flight and consumes the schedule; the host must then run that work and
  /// report [onSyncSucceeded] or [onSyncFailed].
  SyncWorkKind pollDueWork() {
    if (_inFlight) {
      return SyncWorkKind.none;
    }
    if (_kind == SyncWorkKind.none || _dueMicros == null) {
      return SyncWorkKind.none;
    }
    final int now = _nowMicros;
    // A realtime hint (or any work) can never bypass the ordered pull; it is
    // simply scheduled like any other pull below.
    final int runnableAt = _runnableAtMicros();
    if (now < runnableAt) {
      return SyncWorkKind.none;
    }
    if (!_environment.isOnline) {
      return SyncWorkKind.none;
    }
    if (_deferrable && !_environment.allowsBackgroundSync) {
      // Respect data-saver: hold deferrable background/opportunistic work until
      // the environment is unrestricted or a non-deferrable trigger arrives.
      return SyncWorkKind.none;
    }

    final SyncWorkKind kind = _kind;
    _consumeSchedule();
    _inFlight = true;
    return kind;
  }

  /// Reports that the in-flight attempt succeeded. Clears failure backoff.
  void onSyncSucceeded() {
    _inFlight = false;
    _clearBackoff();
  }

  /// Reports that the in-flight attempt failed. Advances the full-jitter
  /// backoff and schedules a retry once the gate elapses.
  void onSyncFailed() {
    _inFlight = false;
    final int attempt = _consecutiveFailures; // 0-based for this failure.
    _consecutiveFailures += 1;
    final Duration delay = _backoff.delayFor(attempt, _entropy);
    final int now = _nowMicros;
    final int backoffUntil = now + delay.inMicroseconds;
    _backoffUntilMicros = backoffUntil;
    // Ensure a retry is scheduled after the backoff gate elapses.
    _kind = mergeWorkKind(_kind, SyncWorkKind.pushAndPull);
    _dueMicros = _earliest(_dueMicros, backoffUntil);
  }

  /// The next monotonic instant the host should poll the scheduler, or null
  /// when nothing is scheduled. Accounts for both the schedule due time and any
  /// active backoff gate.
  int? nextWakeMicros() {
    if (_inFlight || _kind == SyncWorkKind.none || _dueMicros == null) {
      return null;
    }
    return _runnableAtMicros();
  }

  // --- Internals -----------------------------------------------------------

  int _runnableAtMicros() {
    final int due = _dueMicros!;
    final int? gate = _backoffUntilMicros;
    if (gate == null) {
      return due;
    }
    return due > gate ? due : gate;
  }

  void _consumeSchedule() {
    _dueMicros = null;
    _kind = SyncWorkKind.none;
    _deferrable = true;
  }

  void _clearBackoff() {
    _consecutiveFailures = 0;
    _backoffUntilMicros = null;
  }

  static int _earliest(int? existing, int candidate) {
    if (existing == null) {
      return candidate;
    }
    return existing < candidate ? existing : candidate;
  }

  static SyncWorkKind _workFor(SyncTriggerSource source) {
    switch (source) {
      case SyncTriggerSource.manual:
      case SyncTriggerSource.appLaunch:
      case SyncTriggerSource.appResume:
      case SyncTriggerSource.connectivityRegained:
      case SyncTriggerSource.idle:
        return SyncWorkKind.pushAndPull;
      case SyncTriggerSource.appBackground:
      case SyncTriggerSource.localEdit:
        return SyncWorkKind.push;
      case SyncTriggerSource.realtimeHint:
        return SyncWorkKind.pull;
    }
  }
}
