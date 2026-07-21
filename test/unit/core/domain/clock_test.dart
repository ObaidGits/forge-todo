import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/system_clock.dart';
import 'package:forge/core/domain/clock.dart';

void main() {
  test('system clock returns UTC and its injected IANA timezone', () {
    const Clock clock = SystemClock(timezoneIdentifier: 'Europe/London');

    expect(clock.utcNow().isUtc, isTrue);
    expect(clock.timezoneId(), 'Europe/London');
  });

  test('UTC system clock factory uses the canonical IANA identifier', () {
    const Clock clock = SystemClock.utc();

    expect(clock.timezoneId(), 'Etc/UTC');
    expect(clock.utcNow().isUtc, isTrue);
  });

  test('monotonic stamps reject negative elapsed duration', () {
    expect(
      () => MonotonicStamp(const Duration(microseconds: -1)),
      throwsArgumentError,
    );
    expect(
      MonotonicStamp(const Duration(seconds: 2)).elapsedSinceBoot,
      const Duration(seconds: 2),
    );
  });
}
