import 'package:forge/core/domain/clock.dart';

final class FakeClock implements Clock {
  FakeClock({required DateTime initialUtc, this.timezoneIdentifier = 'Etc/UTC'})
    : _currentUtc = _requireUtc(initialUtc);

  DateTime _currentUtc;
  String timezoneIdentifier;

  @override
  DateTime utcNow() => _currentUtc;

  @override
  String timezoneId() => timezoneIdentifier;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must be nonnegative.');
    }
    _currentUtc = _currentUtc.add(duration);
  }

  void setUtc(DateTime value) {
    _currentUtc = _requireUtc(value);
  }

  static DateTime _requireUtc(DateTime value) {
    if (!value.isUtc) {
      throw ArgumentError.value(value, 'value', 'Must be UTC.');
    }
    return value;
  }
}

final class FakeMonotonicClock implements MonotonicClock {
  FakeMonotonicClock({
    Duration initial = Duration.zero,
    this.bootId = 'test-boot-001',
  }) : _elapsed = _requireNonnegative(initial);

  Duration _elapsed;
  String bootId;

  @override
  String bootSessionId() => bootId;

  @override
  MonotonicStamp now() => MonotonicStamp(_elapsed);

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must be nonnegative.');
    }
    _elapsed += duration;
  }

  void reboot({required String newBootId}) {
    if (newBootId.isEmpty || newBootId == bootId) {
      throw ArgumentError.value(
        newBootId,
        'newBootId',
        'Must be nonempty and different.',
      );
    }
    bootId = newBootId;
    _elapsed = Duration.zero;
  }

  static Duration _requireNonnegative(Duration value) {
    if (value.isNegative) {
      throw ArgumentError.value(value, 'value', 'Must be nonnegative.');
    }
    return value;
  }
}
