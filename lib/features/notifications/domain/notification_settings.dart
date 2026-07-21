import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

/// A user-configured quiet-hours window during which reminders are deferred to
/// the resume time rather than fired (R-NOTIFY-006).
///
/// The window is expressed in wall-clock [LocalTime]s and is cross-midnight
/// aware: when [start] is later than [end] the window wraps past midnight
/// (for example 22:00 → 07:00). A reminder whose local fire time lands inside
/// the window is deferred to [end] on the appropriate calendar day.
final class QuietHours {
  const QuietHours({
    required this.enabled,
    required this.start,
    required this.end,
  });

  /// Quiet hours disabled: nothing is ever deferred.
  factory QuietHours.disabled() => QuietHours(
    enabled: false,
    start: LocalTime.midnight,
    end: LocalTime.midnight,
  );

  final bool enabled;
  final LocalTime start;
  final LocalTime end;

  /// Whether the window wraps across midnight (start strictly after end).
  bool get wrapsMidnight => start.compareTo(end) > 0;

  /// Whether [time] falls inside the quiet window. The window is half-open
  /// `[start, end)` so a reminder exactly at the resume time is allowed.
  bool contains(LocalTime time) {
    if (!enabled) {
      return false;
    }
    if (start == end) {
      // Degenerate empty window; treat as "no quiet hours".
      return false;
    }
    final int t = time.secondsOfDay;
    final int s = start.secondsOfDay;
    final int e = end.secondsOfDay;
    if (wrapsMidnight) {
      return t >= s || t < e;
    }
    return t >= s && t < e;
  }

  /// Returns the deferred fire time for [fireLocal] when it lands inside the
  /// window, or [fireLocal] unchanged otherwise.
  ///
  /// For a non-wrapping window the resume time is [end] on the same day. For a
  /// wrapping window a fire time in the pre-midnight part `[start, 24:00)` is
  /// deferred to [end] on the *next* day; a fire time in the post-midnight
  /// part `[00:00, end)` is deferred to [end] on the same day.
  LocalDateTime shift(LocalDateTime fireLocal) {
    if (!contains(fireLocal.time)) {
      return fireLocal;
    }
    final bool nextDay =
        wrapsMidnight && fireLocal.time.secondsOfDay >= start.secondsOfDay;
    final LocalDate date = nextDay ? fireLocal.date.addDays(1) : fireLocal.date;
    return LocalDateTime(date, end);
  }

  @override
  bool operator ==(Object other) =>
      other is QuietHours &&
      other.enabled == enabled &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(enabled, start, end);
}

/// The complete notification settings that govern reconciliation: quiet hours,
/// per-category enablement, the rolling horizon length, and the local OS
/// scheduling budget (R-NOTIFY-004, R-NOTIFY-006).
final class NotificationSettings {
  const NotificationSettings({
    required this.quietHours,
    required this.categoryEnabled,
    this.horizonDays = defaultHorizonDays,
    this.maxScheduled = defaultMaxScheduled,
  });

  /// Sensible defaults: no quiet hours, every category enabled.
  factory NotificationSettings.defaults() => NotificationSettings(
    quietHours: QuietHours.disabled(),
    categoryEnabled: <ReminderCategory, bool>{
      for (final ReminderCategory c in ReminderCategory.values) c: true,
    },
  );

  /// A conservative rolling-horizon length. The reconciler only places OS
  /// notifications inside `[now, now + horizonDays]` and re-runs on launch,
  /// resume, timezone, permission, and data changes (R-NOTIFY-004).
  static const int defaultHorizonDays = 14;

  /// A conservative default local budget on concurrently scheduled OS
  /// notifications; the effective cap is the minimum of this and any platform
  /// pending-request quota.
  static const int defaultMaxScheduled = 60;

  final QuietHours quietHours;
  final Map<ReminderCategory, bool> categoryEnabled;
  final int horizonDays;
  final int maxScheduled;

  bool isCategoryEnabled(ReminderCategory category) =>
      categoryEnabled[category] ?? true;

  NotificationSettings copyWith({
    QuietHours? quietHours,
    Map<ReminderCategory, bool>? categoryEnabled,
    int? horizonDays,
    int? maxScheduled,
  }) => NotificationSettings(
    quietHours: quietHours ?? this.quietHours,
    categoryEnabled: categoryEnabled ?? this.categoryEnabled,
    horizonDays: horizonDays ?? this.horizonDays,
    maxScheduled: maxScheduled ?? this.maxScheduled,
  );
}
