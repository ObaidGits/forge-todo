/// Full-jitter exponential backoff for failed sync attempts (design.md §14
/// "applies exponential backoff with full jitter"; NFR-PERF-005 "back off with
/// jitter").
///
/// The policy is the standard AWS "full jitter" formula:
///
///   ceiling(attempt) = min(cap, base * 2^attempt)
///   delay(attempt)   = random(0, ceiling(attempt))
///
/// The random draw is supplied through an injected [JitterEntropy] port so the
/// delay is deterministic and property-testable; production wraps `dart:math`
/// `Random`, tests supply a fake. All arithmetic is in microseconds and
/// saturates at [cap] before the shift can overflow.
library;

/// A bounded source of non-negative randomness for jitter. Implementations must
/// return a value in `[0, boundExclusive)` and must treat a bound of zero (or
/// less) as always yielding zero.
abstract interface class JitterEntropy {
  /// Returns a value uniformly in `[0, boundExclusive)`, or `0` when
  /// [boundExclusive] is not positive.
  int nextBelow(int boundExclusive);
}

/// A deterministic full-jitter exponential backoff policy. Immutable value.
final class FullJitterBackoff {
  FullJitterBackoff({required this.base, required this.cap}) {
    if (base <= Duration.zero) {
      throw ArgumentError.value(base, 'base', 'Must be positive.');
    }
    if (cap < base) {
      throw ArgumentError.value(cap, 'cap', 'Must be at least the base.');
    }
  }

  /// The base delay used at attempt 0 (before doubling).
  final Duration base;

  /// The maximum delay the exponential ceiling ever reaches.
  final Duration cap;

  /// The exponential ceiling for [attempt] (0-based): `min(cap, base*2^attempt)`
  /// computed without overflow. This is the *upper bound* of the jittered
  /// delay and grows monotonically in [attempt] until it saturates at [cap].
  Duration ceilingFor(int attempt) {
    if (attempt < 0) {
      throw ArgumentError.value(attempt, 'attempt', 'Must be nonnegative.');
    }
    final int capMicros = cap.inMicroseconds;
    final int baseMicros = base.inMicroseconds;
    // Saturate when `base * 2^attempt` would meet or exceed the cap, tested via
    // `base > cap >> attempt` so the left shift below can never overflow a
    // 64-bit int. A shift of 63+ collapses `cap >> attempt` to zero and thus
    // always saturates.
    if (attempt >= 63 || baseMicros > (capMicros >> attempt)) {
      return cap;
    }
    final int doubled = baseMicros << attempt;
    return doubled >= capMicros ? cap : Duration(microseconds: doubled);
  }

  /// The jittered delay for [attempt]: a uniform draw in
  /// `[0, ceilingFor(attempt)]`. The draw is inclusive of the ceiling so the
  /// full window is reachable; callers advancing an attempt counter should pass
  /// the number of prior consecutive failures.
  Duration delayFor(int attempt, JitterEntropy entropy) {
    final int ceilingMicros = ceilingFor(attempt).inMicroseconds;
    // Draw in [0, ceilingMicros]; nextBelow is half-open so add one.
    final int drawn = entropy.nextBelow(ceilingMicros + 1);
    final int clamped = drawn < 0
        ? 0
        : (drawn > ceilingMicros ? ceilingMicros : drawn);
    return Duration(microseconds: clamped);
  }
}
