import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// Production [MonotonicClock] backed by a process [Stopwatch].
///
/// A [Stopwatch] measures elapsed time from a fixed reference using the
/// platform's high-resolution monotonic source, so it never moves backward and
/// is immune to wall-clock adjustments (NTP steps, DST, manual changes). This
/// is exactly the anchor the focus timer and the writer lock need to reason
/// about elapsed time and liveness independent of the wall clock
/// (R-FOCUS-002).
///
/// The [bootSessionId] is minted exactly once per process from the injected
/// [IdGenerator]. Because a fresh process always starts a new stopwatch from
/// zero, pairing a monotonic reading with a per-process boot id lets consumers
/// detect a reboot/relaunch (the id changes and elapsed resets) and refuse to
/// compare monotonic stamps across boots.
final class SystemMonotonicClock implements MonotonicClock {
  SystemMonotonicClock({required IdGenerator idGenerator})
    : _bootSessionId = idGenerator.uuidV7(),
      _stopwatch = Stopwatch()..start();

  final String _bootSessionId;
  final Stopwatch _stopwatch;

  @override
  MonotonicStamp now() => MonotonicStamp(_stopwatch.elapsed);

  @override
  String bootSessionId() => _bootSessionId;
}
