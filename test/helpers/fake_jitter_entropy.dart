import 'dart:math';

import 'package:forge/features/sync/domain/sync_backoff.dart';

/// A deterministic [JitterEntropy] backed by a seeded `Random`, so jittered
/// backoff delays are reproducible in tests.
final class SeededJitterEntropy implements JitterEntropy {
  SeededJitterEntropy(int seed) : _random = Random(seed);

  final Random _random;

  @override
  int nextBelow(int boundExclusive) {
    if (boundExclusive <= 0) {
      return 0;
    }
    // Random.nextInt caps at 2^32; fold larger bounds with a double draw.
    if (boundExclusive <= 0xFFFFFFFF) {
      return _random.nextInt(boundExclusive);
    }
    return (_random.nextDouble() * boundExclusive).floor();
  }
}

/// A [JitterEntropy] that always returns a fixed fraction of the bound, useful
/// for asserting exact boundary behavior (0.0 → always floor, ~1.0 → the top of
/// the half-open window).
final class FixedFractionEntropy implements JitterEntropy {
  FixedFractionEntropy(this.fraction)
    : assert(fraction >= 0.0 && fraction < 1.0, 'fraction in [0, 1)');

  final double fraction;

  @override
  int nextBelow(int boundExclusive) {
    if (boundExclusive <= 0) {
      return 0;
    }
    return (boundExclusive * fraction).floor();
  }
}

/// A [JitterEntropy] that returns the maximum in-window value, i.e.
/// `boundExclusive - 1`. Used to prove the jittered delay never exceeds the
/// exponential ceiling.
final class MaxJitterEntropy implements JitterEntropy {
  const MaxJitterEntropy();

  @override
  int nextBelow(int boundExclusive) =>
      boundExclusive <= 0 ? 0 : boundExclusive - 1;
}
