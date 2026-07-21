import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/id/uuid_v7_generator.dart';

import '../../helpers/fake_clock.dart';

final RegExp _uuidV7 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('UuidV7Generator', () {
    test('emits well-formed lowercase RFC 9562 version 7 values', () {
      final UuidV7Generator generator = UuidV7Generator();
      for (int i = 0; i < 1000; i++) {
        expect(generator.uuidV7(), matches(_uuidV7));
      }
    });

    test('values are unique across a large burst', () {
      final UuidV7Generator generator = UuidV7Generator();
      final Set<String> seen = <String>{};
      for (int i = 0; i < 50000; i++) {
        expect(seen.add(generator.uuidV7()), isTrue);
      }
    });

    test('is monotonic within a single millisecond (dedicated counter)', () {
      // A frozen clock forces every id into the same millisecond, exercising
      // the in-millisecond counter path.
      final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 1, 1));
      final UuidV7Generator generator = UuidV7Generator(clock: clock);
      String previous = generator.uuidV7();
      for (int i = 0; i < 3000; i++) {
        final String next = generator.uuidV7();
        expect(
          next.compareTo(previous),
          greaterThan(0),
          reason: 'ids must strictly increase lexically within one ms',
        );
        previous = next;
      }
    });

    test('is monotonic as the clock advances', () {
      final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 1, 1));
      final UuidV7Generator generator = UuidV7Generator(clock: clock);
      String previous = generator.uuidV7();
      for (int i = 0; i < 500; i++) {
        clock.advance(const Duration(milliseconds: 3));
        final String next = generator.uuidV7();
        expect(next.compareTo(previous), greaterThan(0));
        previous = next;
      }
    });

    test('never regresses when the wall clock steps backward', () {
      final FakeClock clock = FakeClock(
        initialUtc: DateTime.utc(2024, 1, 1, 12),
      );
      final UuidV7Generator generator = UuidV7Generator(clock: clock);
      final String before = generator.uuidV7();
      clock.setUtc(DateTime.utc(2024, 1, 1, 11)); // one hour backward
      final String after = generator.uuidV7();
      expect(after.compareTo(before), greaterThan(0));
    });
  });
}
