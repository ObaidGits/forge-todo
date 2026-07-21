/// Full-jitter exponential backoff (R-SYNC-005, design.md §14; NFR-PERF-005).
///
/// Generative property tests plus example anchors. The jittered delay is always
/// within `[0, min(cap, base*2^attempt)]`, the exponential ceiling grows
/// monotonically in the attempt number and saturates at the cap, and the draw
/// is deterministic for a given entropy source.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/sync_backoff.dart';

import '../helpers/evidence.dart';
import '../helpers/fake_jitter_entropy.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BACKOFF-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.6'),
  requirements: <RequirementId>[RequirementId('R-SYNC-005')],
);

void main() {
  group('FullJitterBackoff properties', () {
    testWithEvidence(
      _evidence('PROP-DELAY-WITHIN-CEILING'),
      'a jittered delay is always within [0, ceilingFor(attempt)] across '
      'randomized policies, attempts, and entropy',
      () {
        for (int seed = 0; seed < 500; seed += 1) {
          final Random rng = Random(seed);
          final int baseMs = 1 + rng.nextInt(2000);
          final int capMs = baseMs + rng.nextInt(60000);
          final FullJitterBackoff policy = FullJitterBackoff(
            base: Duration(milliseconds: baseMs),
            cap: Duration(milliseconds: capMs),
          );
          final int attempt = rng.nextInt(80);
          final Duration ceiling = policy.ceilingFor(attempt);
          final SeededJitterEntropy entropy = SeededJitterEntropy(seed);
          final Duration delay = policy.delayFor(attempt, entropy);

          expect(
            delay.inMicroseconds,
            greaterThanOrEqualTo(0),
            reason: 'negative delay seed=$seed',
          );
          expect(
            delay.inMicroseconds,
            lessThanOrEqualTo(ceiling.inMicroseconds),
            reason: 'delay exceeded ceiling seed=$seed attempt=$attempt',
          );
          expect(
            ceiling.inMicroseconds,
            lessThanOrEqualTo(policy.cap.inMicroseconds),
            reason: 'ceiling exceeded cap seed=$seed',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-CEILING-MONOTONIC-SATURATING'),
      'the exponential ceiling is non-decreasing in attempt and saturates at '
      'the cap',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final int baseMs = 1 + rng.nextInt(1000);
          final int capMs = baseMs + rng.nextInt(120000);
          final FullJitterBackoff policy = FullJitterBackoff(
            base: Duration(milliseconds: baseMs),
            cap: Duration(milliseconds: capMs),
          );
          Duration previous = policy.ceilingFor(0);
          expect(
            previous.inMicroseconds,
            lessThanOrEqualTo(policy.cap.inMicroseconds),
          );
          for (int attempt = 1; attempt < 70; attempt += 1) {
            final Duration current = policy.ceilingFor(attempt);
            expect(
              current.inMicroseconds,
              greaterThanOrEqualTo(previous.inMicroseconds),
              reason: 'ceiling decreased seed=$seed attempt=$attempt',
            );
            expect(
              current.inMicroseconds,
              lessThanOrEqualTo(policy.cap.inMicroseconds),
              reason: 'ceiling exceeded cap seed=$seed attempt=$attempt',
            );
            previous = current;
          }
          // Deep attempts always saturate exactly at the cap.
          expect(policy.ceilingFor(1000), policy.cap);
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-DETERMINISTIC'),
      'the same entropy seed and attempt yield the same delay',
      () {
        final FullJitterBackoff policy = FullJitterBackoff(
          base: const Duration(milliseconds: 250),
          cap: const Duration(seconds: 30),
        );
        for (int attempt = 0; attempt < 20; attempt += 1) {
          final Duration a = policy.delayFor(attempt, SeededJitterEntropy(7));
          final Duration b = policy.delayFor(attempt, SeededJitterEntropy(7));
          expect(a, b, reason: 'non-deterministic at attempt=$attempt');
        }
      },
    );
  });

  group('FullJitterBackoff examples', () {
    testWithEvidence(
      _evidence('CEILING-DOUBLES-FROM-BASE'),
      'the ceiling doubles from the base until it reaches the cap',
      () {
        final FullJitterBackoff policy = FullJitterBackoff(
          base: const Duration(seconds: 1),
          cap: const Duration(seconds: 10),
        );
        expect(policy.ceilingFor(0), const Duration(seconds: 1));
        expect(policy.ceilingFor(1), const Duration(seconds: 2));
        expect(policy.ceilingFor(2), const Duration(seconds: 4));
        expect(policy.ceilingFor(3), const Duration(seconds: 8));
        // 16s would exceed the 10s cap: saturate.
        expect(policy.ceilingFor(4), const Duration(seconds: 10));
        expect(policy.ceilingFor(5), const Duration(seconds: 10));
      },
    );

    testWithEvidence(
      _evidence('ZERO-JITTER-IS-FLOOR'),
      'zero-fraction entropy yields a zero delay (the bottom of the window)',
      () {
        final FullJitterBackoff policy = FullJitterBackoff(
          base: const Duration(seconds: 1),
          cap: const Duration(seconds: 10),
        );
        expect(policy.delayFor(3, FixedFractionEntropy(0.0)), Duration.zero);
      },
    );

    testWithEvidence(
      _evidence('MAX-JITTER-HITS-CEILING'),
      'max entropy yields exactly the exponential ceiling',
      () {
        final FullJitterBackoff policy = FullJitterBackoff(
          base: const Duration(seconds: 1),
          cap: const Duration(seconds: 10),
        );
        expect(
          policy.delayFor(2, const MaxJitterEntropy()),
          const Duration(seconds: 4),
        );
        expect(
          policy.delayFor(9, const MaxJitterEntropy()),
          const Duration(seconds: 10),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-INVALID-POLICY'),
      'a cap below the base and a nonpositive base are rejected',
      () {
        expect(
          () => FullJitterBackoff(
            base: const Duration(seconds: 5),
            cap: const Duration(seconds: 1),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => FullJitterBackoff(
            base: Duration.zero,
            cap: const Duration(seconds: 1),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
