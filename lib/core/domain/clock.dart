abstract interface class Clock {
  DateTime utcNow();

  /// IANA timezone identifier used to interpret local date/time intent.
  String timezoneId();
}

final class MonotonicStamp {
  MonotonicStamp(Duration elapsedSinceBoot)
    : elapsedSinceBoot = _validate(elapsedSinceBoot);

  final Duration elapsedSinceBoot;

  static Duration _validate(Duration value) {
    if (value.isNegative) {
      throw ArgumentError.value(
        value,
        'elapsedSinceBoot',
        'Must be nonnegative.',
      );
    }
    return value;
  }
}

abstract interface class MonotonicClock {
  MonotonicStamp now();

  String bootSessionId();
}
