import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/id/uuid_v7_generator.dart';
import 'package:forge/app/infrastructure/system_monotonic_clock.dart';
import 'package:forge/core/domain/clock.dart';

void main() {
  group('SystemMonotonicClock', () {
    test('mints one stable, non-empty boot session id per process', () {
      final SystemMonotonicClock clock = SystemMonotonicClock(
        idGenerator: UuidV7Generator(),
      );
      final String first = clock.bootSessionId();
      expect(first, isNotEmpty);
      // Stable across calls: the boot id is minted once per instance.
      expect(clock.bootSessionId(), first);
    });

    test('distinct instances model distinct boots with distinct ids', () {
      final UuidV7Generator ids = UuidV7Generator();
      final SystemMonotonicClock a = SystemMonotonicClock(idGenerator: ids);
      final SystemMonotonicClock b = SystemMonotonicClock(idGenerator: ids);
      expect(a.bootSessionId(), isNot(b.bootSessionId()));
    });

    test('now() is nonnegative and never moves backward', () async {
      final SystemMonotonicClock clock = SystemMonotonicClock(
        idGenerator: UuidV7Generator(),
      );
      MonotonicStamp previous = clock.now();
      expect(previous.elapsedSinceBoot >= Duration.zero, isTrue);
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final MonotonicStamp next = clock.now();
        expect(
          next.elapsedSinceBoot >= previous.elapsedSinceBoot,
          isTrue,
          reason: 'monotonic time must never regress',
        );
        previous = next;
      }
    });
  });
}
