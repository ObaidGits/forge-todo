import 'package:forge/core/domain/clock.dart';

/// Process clock adapter. The timezone is injected because Dart's local
/// timezone abbreviation is not an IANA identifier.
final class SystemClock implements Clock {
  const SystemClock({required this.timezoneIdentifier});

  const SystemClock.utc() : timezoneIdentifier = 'Etc/UTC';

  final String timezoneIdentifier;

  @override
  String timezoneId() => timezoneIdentifier;

  @override
  DateTime utcNow() => DateTime.now().toUtc();
}
