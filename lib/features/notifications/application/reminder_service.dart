import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_scheduler.dart';
import 'package:forge/features/notifications/domain/notification_settings.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';
import 'package:forge/features/notifications/domain/reminder_repository.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

/// Resolves the owner anchor instant for an [OffsetTrigger] reminder (the
/// owner's due instant). Returns null when the owner has no anchor (for
/// example a task with no instant due), in which case the reminder is not
/// scheduled this pass.
abstract interface class ReminderAnchorResolver {
  Future<int?> anchorUtc({
    required String profileId,
    required ReminderOwnerType ownerType,
    required String ownerId,
  });
}

/// A no-op anchor resolver used when no offset reminders are wired.
final class NullAnchorResolver implements ReminderAnchorResolver {
  const NullAnchorResolver();

  @override
  Future<int?> anchorUtc({
    required String profileId,
    required ReminderOwnerType ownerType,
    required String ownerId,
  }) async => null;
}

/// Loads the active notification settings for a profile (R-NOTIFY-006).
abstract interface class NotificationSettingsStore {
  Future<NotificationSettings> load(String profileId);
}

/// Default settings store returning built-in defaults; overridden by a durable
/// settings-backed implementation at the composition root.
final class DefaultNotificationSettingsStore
    implements NotificationSettingsStore {
  const DefaultNotificationSettingsStore();

  @override
  Future<NotificationSettings> load(String profileId) async =>
      NotificationSettings.defaults();
}

/// Persists the local-only reconciliation projection (cached next-fire,
/// delivery status, last diagnostic) back onto reminder rows so reminder
/// details can render honest state (R-NOTIFY-003). Local-only per data-model.
abstract interface class ReminderProjectionWriter {
  Future<void> record({
    required String profileId,
    required List<Reminder> reminders,
    required Map<String, int> placed,
    required List<ReminderDiagnostic> diagnostics,
    required int nowUtc,
  });
}

/// The result of one reconciliation pass returned to callers/tests.
final class ReconciliationOutcome {
  const ReconciliationOutcome({
    required this.report,
    required this.consideredCount,
    required this.resolvedCount,
    required this.trigger,
  });

  final ScheduleReport report;

  /// The number of enabled reminders inspected.
  final int consideredCount;

  /// The number that resolved to a concrete fire instant.
  final int resolvedCount;

  final ReconciliationTrigger trigger;

  List<ReminderDiagnostic> get diagnostics => report.diagnostics;
}

/// The outcome of a contextual permission request (R-NOTIFY-002).
final class PermissionOutcome {
  const PermissionOutcome({
    required this.explanationShown,
    required this.status,
    required this.requested,
  });

  /// Whether a pre-permission explanation was presented before the OS prompt.
  final bool explanationShown;

  /// The resulting permission status.
  final PermissionStatus status;

  /// Whether the OS prompt was actually invoked this call.
  final bool requested;
}

/// The one unified MVP reminder scheduling service (R-NOTIFY-001..006).
///
/// It owns the rolling-horizon reconciliation loop for every aggregate type,
/// resolves each reminder to a deterministic UTC instant (timezone + quiet
/// hours), delegates OS placement to the [ReminderScheduler] port, and returns
/// visible diagnostics. It performs no plugin work directly — OS scheduling
/// stays behind ports so it is fully testable with fakes.
final class ReminderService {
  ReminderService({
    required this.reads,
    required this.scheduler,
    required this.transport,
    required this.resolver,
    required this.clock,
    this.settingsStore = const DefaultNotificationSettingsStore(),
    this.anchorResolver = const NullAnchorResolver(),
    this.projection,
  });

  final ReminderReadRepository reads;
  final ReminderScheduler scheduler;
  final NotificationTransport transport;
  final TimeZoneResolver resolver;
  final Clock clock;
  final NotificationSettingsStore settingsStore;
  final ReminderAnchorResolver anchorResolver;
  final ReminderProjectionWriter? projection;

  static const int _microsPerDay = Duration.microsecondsPerDay;

  /// Reconciles the rolling horizon on any of the R-NOTIFY-004 triggers
  /// (launch/resume/timezone/permission/data change). Deterministic: the same
  /// reminders, clock, and settings always produce the same plan.
  Future<ReconciliationOutcome> reconcile(
    String profileId,
    ReconciliationTrigger trigger,
  ) async {
    final NotificationSettings settings = await settingsStore.load(profileId);
    final List<Reminder> reminders = await reads.enabledReminders(profileId);
    final int nowUtc = clock.utcNow().microsecondsSinceEpoch;
    final int horizonEndUtc = nowUtc + settings.horizonDays * _microsPerDay;

    final List<ResolvedReminder> resolved = <ResolvedReminder>[];
    for (final Reminder reminder in reminders) {
      final int? fireAtUtc = await _resolveFireAtUtc(
        profileId,
        reminder,
        settings,
      );
      if (fireAtUtc == null) {
        continue;
      }
      resolved.add(
        ResolvedReminder(
          reminderId: reminder.id.value,
          category: reminder.category,
          fireAtUtc: fireAtUtc,
        ),
      );
    }

    final ScheduleReport report = await scheduler.reconcile(
      ReminderHorizon(
        nowUtc: nowUtc,
        horizonEndUtc: horizonEndUtc,
        resolved: resolved,
        settings: settings,
        trigger: trigger,
      ),
    );

    await projection?.record(
      profileId: profileId,
      reminders: reminders,
      placed: report.placed,
      diagnostics: report.diagnostics,
      nowUtc: nowUtc,
    );

    return ReconciliationOutcome(
      report: report,
      consideredCount: reminders.length,
      resolvedCount: resolved.length,
      trigger: trigger,
    );
  }

  /// Contextually requests notification permission after the user creates or
  /// enables a reminder, presenting a pre-permission explanation where the
  /// platform allows another prompt (R-NOTIFY-002). Idempotent: if permission
  /// is already resolved, no OS prompt is invoked.
  Future<PermissionOutcome> requestPermissionAfterEnable() async {
    final SchedulerCapability capability = await transport.capability();
    if (!capability.permission.canRequest) {
      return PermissionOutcome(
        explanationShown: false,
        status: capability.permission,
        requested: false,
      );
    }
    // The pre-permission explanation is presentation's responsibility; the
    // service records that it must precede the OS prompt and only then asks.
    final PermissionStatus status = await transport.requestPermission();
    return PermissionOutcome(
      explanationShown: true,
      status: status,
      requested: true,
    );
  }

  /// Resolves a reminder to its next absolute fire instant (UTC micros),
  /// applying timezone resolution and quiet-hours deferral, or null when it
  /// cannot be computed (unknown zone or missing owner anchor).
  Future<int?> _resolveFireAtUtc(
    String profileId,
    Reminder reminder,
    NotificationSettings settings,
  ) async {
    if (!resolver.supportsZone(reminder.timezoneId)) {
      return null;
    }
    // A live one-shot snooze overrides the trigger until it passes
    // (R-NOTIFY-005). Quiet hours do not defer an explicit user snooze.
    final int? snoozedUntil = reminder.snoozedUntilUtc;
    if (snoozedUntil != null &&
        snoozedUntil > clock.utcNow().microsecondsSinceEpoch) {
      return snoozedUntil;
    }
    final LocalDateTime? fireLocal = await _fireLocal(profileId, reminder);
    if (fireLocal == null) {
      return null;
    }
    final LocalDateTime shifted = settings.quietHours.shift(fireLocal);
    final ZonedInstant instant = resolver.toInstant(
      reminder.timezoneId,
      shifted,
      policy: reminder.dstPolicy,
    );
    return instant.utcMicros;
  }

  Future<LocalDateTime?> _fireLocal(String profileId, Reminder reminder) async {
    final ReminderTrigger trigger = reminder.trigger;
    switch (trigger) {
      case AbsoluteLocalTrigger(:final LocalDateTime local):
        return local;
      case OffsetTrigger(:final int offsetMinutes):
        final int? anchorUtc = await anchorResolver.anchorUtc(
          profileId: profileId,
          ownerType: reminder.ownerType,
          ownerId: reminder.ownerId,
        );
        if (anchorUtc == null) {
          return null;
        }
        final int fireUtc =
            anchorUtc - offsetMinutes * Duration.microsecondsPerMinute;
        return resolver.toLocal(reminder.timezoneId, fireUtc);
    }
  }
}
