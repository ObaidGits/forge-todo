import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';

/// Deterministic DST/timezone conversion tests over the pinned timezone
/// database.
///
/// **Validates: Requirements R-GEN-004**
void main() {
  late TimeZoneResolver resolver;

  setUp(() {
    resolver = TimezonePackageResolver.initialized();
  });

  int microsOf(int y, int mo, int d, int h, int mi) =>
      DateTime.utc(y, mo, d, h, mi).microsecondsSinceEpoch;

  group('supportsZone', () {
    test('accepts known IANA zones and rejects unknown ones', () {
      expect(resolver.supportsZone('America/New_York'), isTrue);
      expect(resolver.supportsZone('Etc/UTC'), isTrue);
      expect(resolver.supportsZone('Mars/Olympus_Mons'), isFalse);
    });

    test('throws for an unknown zone on conversion', () {
      expect(
        () => resolver.toInstant(
          'Mars/Olympus_Mons',
          LocalDateTime(LocalDate(2024, 1, 1), LocalTime(9, 0)),
        ),
        throwsA(isA<UnknownTimeZoneError>()),
      );
    });
  });

  group('standard offsets', () {
    test('New York winter is UTC-5', () {
      // 2024-01-15 09:00 America/New_York (EST) == 14:00 UTC.
      final ZonedInstant instant = resolver.toInstant(
        'America/New_York',
        LocalDateTime(LocalDate(2024, 1, 15), LocalTime(9, 0)),
      );
      expect(instant.utcMicros, microsOf(2024, 1, 15, 14, 0));
      expect(instant.offsetSeconds, -5 * 3600);
      expect(instant.wasGap, isFalse);
      expect(instant.wasOverlap, isFalse);
    });

    test('New York summer is UTC-4', () {
      // 2024-07-15 09:00 America/New_York (EDT) == 13:00 UTC.
      final ZonedInstant instant = resolver.toInstant(
        'America/New_York',
        LocalDateTime(LocalDate(2024, 7, 15), LocalTime(9, 0)),
      );
      expect(instant.utcMicros, microsOf(2024, 7, 15, 13, 0));
      expect(instant.offsetSeconds, -4 * 3600);
    });
  });

  group('spring-forward gap', () {
    // On 2024-03-10 America/New_York jumps 02:00 EST -> 03:00 EDT; 02:30 never
    // occurs.
    final LocalDateTime gap = LocalDateTime(
      LocalDate(2024, 3, 10),
      LocalTime(2, 30),
    );

    test('forward policy maps the gap to the pre-transition offset', () {
      final ZonedInstant instant = resolver.toInstant('America/New_York', gap);
      expect(instant.wasGap, isTrue);
      // Forward gap uses the pre-transition (EST, -5) offset: 02:30 - (-5) =
      // 07:30 UTC, which lands at 03:30 EDT wall time.
      expect(instant.utcMicros, microsOf(2024, 3, 10, 7, 30));
    });

    test('backward policy maps the gap to the post-transition offset', () {
      final ZonedInstant instant = resolver.toInstant(
        'America/New_York',
        gap,
        policy: DstPolicy.backwardGapLaterOverlap,
      );
      expect(instant.wasGap, isTrue);
      // Backward gap uses the post-transition (EDT, -4) offset: 02:30 - (-4) =
      // 06:30 UTC.
      expect(instant.utcMicros, microsOf(2024, 3, 10, 6, 30));
    });

    test('the two policies differ by exactly the one-hour gap', () {
      final int forward = resolver.toInstant('America/New_York', gap).utcMicros;
      final int backward = resolver
          .toInstant(
            'America/New_York',
            gap,
            policy: DstPolicy.backwardGapLaterOverlap,
          )
          .utcMicros;
      expect(forward - backward, Duration.microsecondsPerHour);
    });
  });

  group('fall-back overlap', () {
    // On 2024-11-03 America/New_York repeats 01:00-02:00; 01:30 occurs twice.
    final LocalDateTime overlap = LocalDateTime(
      LocalDate(2024, 11, 3),
      LocalTime(1, 30),
    );

    test('earlier policy chooses the first (EDT) instant', () {
      final ZonedInstant instant = resolver.toInstant(
        'America/New_York',
        overlap,
      );
      expect(instant.wasOverlap, isTrue);
      // Earlier occurrence uses EDT (-4): 01:30 - (-4) = 05:30 UTC.
      expect(instant.utcMicros, microsOf(2024, 11, 3, 5, 30));
    });

    test('later policy chooses the second (EST) instant', () {
      final ZonedInstant instant = resolver.toInstant(
        'America/New_York',
        overlap,
        policy: DstPolicy.backwardGapLaterOverlap,
      );
      expect(instant.wasOverlap, isTrue);
      // Later occurrence uses EST (-5): 01:30 - (-5) = 06:30 UTC.
      expect(instant.utcMicros, microsOf(2024, 11, 3, 6, 30));
    });
  });

  group('round trip', () {
    test('toLocal inverts a standard-offset instant', () {
      final LocalDateTime local = resolver.toLocal(
        'America/New_York',
        microsOf(2024, 7, 15, 13, 0),
      );
      expect(local.date, LocalDate(2024, 7, 15));
      expect(local.time, LocalTime(9, 0));
    });

    test('conversion is deterministic across repeated calls', () {
      final ZonedInstant a = resolver.toInstant(
        'Europe/London',
        LocalDateTime(LocalDate(2024, 6, 1), LocalTime(9, 0)),
      );
      final ZonedInstant b = resolver.toInstant(
        'Europe/London',
        LocalDateTime(LocalDate(2024, 6, 1), LocalTime(9, 0)),
      );
      expect(a, b);
    });
  });
}
