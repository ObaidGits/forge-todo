import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Production [TimeZoneResolver] over the pinned `timezone` package
/// (data-model §5, R-GEN-004).
///
/// This adapter lives at the infrastructure boundary so domain policies never
/// import a timezone database. The embedded IANA database is pinned with the
/// `timezone` package version, so a given wall-clock time always resolves to
/// the same absolute instant across devices and runs — the determinism
/// R-GEN-004 requires.
///
/// DST resolution is explicit rather than delegated to the library's internal
/// default: for each wall-clock time it computes the candidate instants under
/// the offsets in effect on either side of a possible transition and selects
/// one by the requested [DstPolicy], flagging gaps and overlaps.
final class TimezonePackageResolver implements TimeZoneResolver {
  TimezonePackageResolver._();

  bool _initialized = false;

  /// Builds a resolver with the embedded IANA database initialized.
  factory TimezonePackageResolver.initialized() {
    final TimezonePackageResolver resolver = TimezonePackageResolver._();
    resolver._ensureInitialized();
    return resolver;
  }

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    tzdata.initializeTimeZones();
    _initialized = true;
  }

  // A two-day probe reliably straddles at most one DST transition, so it
  // captures the standard and daylight offsets bracketing any wall-clock time.
  static const int _probeMicros = 2 * Duration.microsecondsPerDay;

  @override
  bool supportsZone(String timezoneId) {
    _ensureInitialized();
    try {
      tz.getLocation(timezoneId);
      return true;
    } on tz.LocationNotFoundException {
      return false;
    }
  }

  @override
  ZonedInstant toInstant(
    String timezoneId,
    LocalDateTime local, {
    DstPolicy policy = DstPolicy.forwardGapEarlierOverlap,
  }) {
    _ensureInitialized();
    final tz.Location location = _location(timezoneId);
    final int wall = DateTime.utc(
      local.date.year,
      local.date.month,
      local.date.day,
      local.time.hour,
      local.time.minute,
      local.time.second,
    ).microsecondsSinceEpoch;

    final int offPre = _offsetMicrosAt(location, wall - _probeMicros);
    final int offPost = _offsetMicrosAt(location, wall + _probeMicros);

    if (offPre == offPost) {
      final int utc = wall - offPre;
      return ZonedInstant(
        utcMicros: utc,
        timezoneId: timezoneId,
        offsetSeconds: offPre ~/ Duration.microsecondsPerSecond,
      );
    }

    final int candidatePre = wall - offPre;
    final int candidatePost = wall - offPost;
    final bool validPre = _offsetMicrosAt(location, candidatePre) == offPre;
    final bool validPost = _offsetMicrosAt(location, candidatePost) == offPost;

    final bool preferPre = policy == DstPolicy.forwardGapEarlierOverlap;

    int chosen;
    bool wasGap = false;
    bool wasOverlap = false;
    if (validPre && validPost) {
      // Fall-back overlap: the wall time occurs twice.
      wasOverlap = true;
      chosen = preferPre ? candidatePre : candidatePost;
    } else if (validPre != validPost) {
      // Unambiguous: the wall time maps cleanly to one side of the transition.
      chosen = validPre ? candidatePre : candidatePost;
    } else {
      // Spring-forward gap: the wall time never occurs.
      wasGap = true;
      chosen = preferPre ? candidatePre : candidatePost;
    }

    return ZonedInstant(
      utcMicros: chosen,
      timezoneId: timezoneId,
      offsetSeconds:
          _offsetMicrosAt(location, chosen) ~/ Duration.microsecondsPerSecond,
      wasGap: wasGap,
      wasOverlap: wasOverlap,
    );
  }

  @override
  LocalDateTime toLocal(String timezoneId, int utcMicros) {
    _ensureInitialized();
    final tz.Location location = _location(timezoneId);
    final int offset = _offsetMicrosAt(location, utcMicros);
    final DateTime wall = DateTime.fromMicrosecondsSinceEpoch(
      utcMicros + offset,
      isUtc: true,
    );
    return LocalDateTime(
      LocalDate(wall.year, wall.month, wall.day),
      LocalTime(wall.hour, wall.minute, wall.second),
    );
  }

  tz.Location _location(String timezoneId) {
    try {
      return tz.getLocation(timezoneId);
    } on tz.LocationNotFoundException {
      throw UnknownTimeZoneError(timezoneId);
    }
  }

  int _offsetMicrosAt(tz.Location location, int utcMicros) {
    final int millis = utcMicros ~/ Duration.microsecondsPerMillisecond;
    return location.timeZone(millis).offset.inMilliseconds *
        Duration.microsecondsPerMillisecond;
  }
}
