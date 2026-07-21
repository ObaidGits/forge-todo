import 'package:forge/core/domain/local_date.dart';

/// A timezone-free wall-clock date and time (no offset).
///
/// A [LocalTime] plus a [LocalDate] describe what a clock on a wall reads; they
/// carry no timezone. Converting a [LocalDateTime] to an absolute UTC instant
/// requires a `TimeZoneResolver`, which is where all DST behavior lives
/// (R-GEN-004). Keeping this type pure means recurrence math never accidentally
/// depends on the host timezone.
final class LocalTime implements Comparable<LocalTime> {
  factory LocalTime(int hour, int minute, [int second = 0]) {
    if (hour < 0 || hour > 23) {
      throw FormatException('Hour must be 0..23: $hour');
    }
    if (minute < 0 || minute > 59) {
      throw FormatException('Minute must be 0..59: $minute');
    }
    if (second < 0 || second > 59) {
      throw FormatException('Second must be 0..59: $second');
    }
    return LocalTime._(hour, minute, second);
  }

  const LocalTime._(this.hour, this.minute, this.second);

  /// Midnight (00:00:00).
  static const LocalTime midnight = LocalTime._(0, 0, 0);

  /// Parses an ISO `HH:MM` or `HH:MM:SS` value.
  factory LocalTime.parse(String value) {
    final Match? match = _pattern.firstMatch(value);
    if (match == null) {
      throw FormatException('Expected HH:MM[:SS]: $value');
    }
    return LocalTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      match.group(3) == null ? 0 : int.parse(match.group(3)!),
    );
  }

  /// Rebuilds a time from a seconds-since-midnight value (0..86399).
  factory LocalTime.fromSecondsOfDay(int seconds) {
    if (seconds < 0 || seconds >= Duration.secondsPerDay) {
      throw FormatException('Seconds-of-day must be 0..86399: $seconds');
    }
    return LocalTime._(seconds ~/ 3600, (seconds % 3600) ~/ 60, seconds % 60);
  }

  final int hour;
  final int minute;
  final int second;

  static final RegExp _pattern = RegExp(r'^(\d{2}):(\d{2})(?::(\d{2}))?$');

  /// Seconds since local midnight; the compact persisted form.
  int get secondsOfDay => hour * 3600 + minute * 60 + second;

  String get iso => '${_pad(hour)}:${_pad(minute)}:${_pad(second)}';

  @override
  int compareTo(LocalTime other) => secondsOfDay.compareTo(other.secondsOfDay);

  @override
  bool operator ==(Object other) =>
      other is LocalTime &&
      other.hour == hour &&
      other.minute == minute &&
      other.second == second;

  @override
  int get hashCode => Object.hash(hour, minute, second);

  @override
  String toString() => iso;

  static String _pad(int value) => value.toString().padLeft(2, '0');
}

/// A wall-clock date and time with no timezone attached.
final class LocalDateTime implements Comparable<LocalDateTime> {
  const LocalDateTime(this.date, this.time);

  /// Combines a date with midnight.
  LocalDateTime.atMidnight(LocalDate date) : this(date, LocalTime.midnight);

  final LocalDate date;
  final LocalTime time;

  String get iso => '${date.iso}T${time.iso}';

  @override
  int compareTo(LocalDateTime other) {
    final int byDate = date.compareTo(other.date);
    return byDate != 0 ? byDate : time.compareTo(other.time);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDateTime && other.date == date && other.time == time;

  @override
  int get hashCode => Object.hash(date, time);

  @override
  String toString() => iso;
}
