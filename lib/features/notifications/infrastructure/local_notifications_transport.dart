import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';
import 'package:timezone/timezone.dart' as tz;

/// The single production [NotificationTransport] over
/// [FlutterLocalNotificationsPlugin] (design §9, R-NOTIFY-003/004).
///
/// This is the only file in the codebase allowed to touch the platform
/// notification plugin: [ReminderService] and the pure [HorizonReconciler] stay
/// plugin-free and depend solely on the [NotificationTransport] port. Every
/// plugin interaction is defensive — initialization, permission, and each
/// scheduler operation are wrapped so a missing notification daemon, denied
/// permission, or any plugin exception degrades to an honest
/// [SchedulerCapability]/[NotificationTransportException] instead of crashing or
/// blocking the UI (R-NOTIFY-003).
final class LocalNotificationsTransport implements NotificationTransport {
  LocalNotificationsTransport({
    FlutterLocalNotificationsPlugin? plugin,
    TargetPlatform? platformOverride,
    bool? isWebOverride,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _platform = platformOverride ?? defaultTargetPlatform,
       _isWeb = isWebOverride ?? kIsWeb;

  final FlutterLocalNotificationsPlugin _plugin;
  final TargetPlatform _platform;
  final bool _isWeb;

  /// The Android notification channel reminders are posted to. Created lazily by
  /// the plugin on first schedule. Mobile builds still need the matching native
  /// channel/manifest/plist entries (tracked as follow-up mobile work; the
  /// Linux desktop path needs no native config).
  static const String _androidChannelId = 'forge_reminders';
  static const String _androidChannelName = 'Reminders';
  static const String _androidChannelDescription =
      'Scheduled task, habit, study, and deadline reminders.';

  static const String _initFailureEvidence = 'LOCAL-NOTIFICATIONS-INIT-FAILED';
  static const String _noSchedulerEvidence = 'LOCAL-NOTIFICATIONS-UNAVAILABLE';
  static const String _readyEvidence = 'LOCAL-NOTIFICATIONS-READY';

  _InitState _initState = _InitState.pending;

  /// The last permission status observed via a contextual request; used to
  /// answer [capability] on Darwin platforms where a cheap definitive read is
  /// not available without prompting.
  PermissionStatus _lastKnownPermission = PermissionStatus.notDetermined;

  /// Whether exact alarms were available at the last [capability] read; used to
  /// pick the Android schedule mode without re-probing on every [schedule].
  bool _exactAlarmsAvailable = true;

  bool get _isAndroid => !_isWeb && _platform == TargetPlatform.android;
  bool get _isIOS => !_isWeb && _platform == TargetPlatform.iOS;
  bool get _isMacOS => !_isWeb && _platform == TargetPlatform.macOS;
  bool get _isLinux => !_isWeb && _platform == TargetPlatform.linux;

  @override
  Future<SchedulerCapability> capability() async {
    if (!await _ensureInitialized()) {
      return const SchedulerCapability(
        permission: PermissionStatus.denied,
        available: false,
        exactAlarms: false,
        actionsSupported: false,
        evidenceId: _initFailureEvidence,
      );
    }
    try {
      if (_isAndroid) {
        final AndroidFlutterLocalNotificationsPlugin? android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final bool enabled =
            (await android?.areNotificationsEnabled()) ?? false;
        final bool exact =
            (await android?.canScheduleExactNotifications()) ?? false;
        _exactAlarmsAvailable = exact;
        return SchedulerCapability(
          permission: enabled
              ? PermissionStatus.granted
              : PermissionStatus.denied,
          available: true,
          exactAlarms: exact,
          actionsSupported: true,
          evidenceId: _readyEvidence,
        );
      }
      if (_isIOS || _isMacOS) {
        _exactAlarmsAvailable = true;
        return SchedulerCapability(
          permission: _lastKnownPermission,
          available: true,
          exactAlarms: true,
          actionsSupported: true,
          evidenceId: _readyEvidence,
        );
      }
      if (_isLinux) {
        // Probe the notification daemon. A missing daemon (common on headless
        // or minimal desktops) must degrade gracefully, never throw.
        final LinuxFlutterLocalNotificationsPlugin? linux = _plugin
            .resolvePlatformSpecificImplementation<
              LinuxFlutterLocalNotificationsPlugin
            >();
        try {
          await linux?.getCapabilities();
        } on Object {
          _exactAlarmsAvailable = false;
          return const SchedulerCapability(
            permission: PermissionStatus.granted,
            available: false,
            exactAlarms: false,
            actionsSupported: false,
            evidenceId: _noSchedulerEvidence,
          );
        }
        _exactAlarmsAvailable = true;
        return const SchedulerCapability(
          permission: PermissionStatus.granted,
          available: true,
          exactAlarms: true,
          actionsSupported: true,
          evidenceId: _readyEvidence,
        );
      }
      // Unknown / web platform: conservatively report no scheduler.
      _exactAlarmsAvailable = false;
      return const SchedulerCapability(
        permission: PermissionStatus.denied,
        available: false,
        exactAlarms: false,
        actionsSupported: false,
        evidenceId: _noSchedulerEvidence,
      );
    } on Object {
      _exactAlarmsAvailable = false;
      return const SchedulerCapability(
        permission: PermissionStatus.denied,
        available: false,
        exactAlarms: false,
        actionsSupported: false,
        evidenceId: _noSchedulerEvidence,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!await _ensureInitialized()) {
      return PermissionStatus.denied;
    }
    try {
      if (_isAndroid) {
        final AndroidFlutterLocalNotificationsPlugin? android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final bool granted =
            (await android?.requestNotificationsPermission()) ?? false;
        return _lastKnownPermission = granted
            ? PermissionStatus.granted
            : PermissionStatus.denied;
      }
      if (_isIOS) {
        final IOSFlutterLocalNotificationsPlugin? ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final bool granted =
            (await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            )) ??
            false;
        return _lastKnownPermission = granted
            ? PermissionStatus.granted
            : PermissionStatus.denied;
      }
      if (_isMacOS) {
        final MacOSFlutterLocalNotificationsPlugin? macos = _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        final bool granted =
            (await macos?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            )) ??
            false;
        return _lastKnownPermission = granted
            ? PermissionStatus.granted
            : PermissionStatus.denied;
      }
      // Linux and other desktops have no per-app notification permission model;
      // delivery is governed by the daemon's presence, reported by capability().
      return _lastKnownPermission = PermissionStatus.granted;
    } on Object {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<List<ScheduledNotification>> pending() async {
    if (!await _ensureInitialized()) {
      return const <ScheduledNotification>[];
    }
    try {
      final List<PendingNotificationRequest> requests = await _plugin
          .pendingNotificationRequests();
      final List<ScheduledNotification> out = <ScheduledNotification>[];
      for (final PendingNotificationRequest request in requests) {
        final ScheduledNotification? decoded = _decodePayload(request.payload);
        if (decoded != null) {
          out.add(decoded);
        }
      }
      return out;
    } on Object {
      return const <ScheduledNotification>[];
    }
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    if (!await _ensureInitialized()) {
      throw const NotificationTransportException(
        'Notification transport is unavailable on this platform.',
      );
    }
    try {
      final tz.TZDateTime fireAt = tz.TZDateTime.from(
        DateTime.fromMicrosecondsSinceEpoch(
          notification.fireAtUtc,
          isUtc: true,
        ),
        tz.UTC,
      );
      await _plugin.zonedSchedule(
        id: _osId(notification.reminderId),
        title: _titleFor(notification.category),
        body: _bodyFor(notification.category),
        scheduledDate: fireAt,
        notificationDetails: _detailsFor(),
        androidScheduleMode: _exactAlarmsAvailable
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: _encodePayload(notification),
      );
    } on NotificationTransportException {
      rethrow;
    } on Object catch (error) {
      throw NotificationTransportException(
        'OS scheduler rejected reminder ${notification.reminderId}: $error',
      );
    }
  }

  @override
  Future<bool> cancel(String reminderId) async {
    if (!await _ensureInitialized()) {
      return false;
    }
    final int osId = _osId(reminderId);
    try {
      final List<PendingNotificationRequest> requests = await _plugin
          .pendingNotificationRequests();
      final bool present = requests.any(
        (PendingNotificationRequest r) => r.id == osId,
      );
      await _plugin.cancel(id: osId);
      return present;
    } on Object {
      return false;
    }
  }

  /// Lazily initializes the plugin exactly once. Returns whether the plugin is
  /// ready; a failure is remembered so repeated reconciliations do not re-probe
  /// a broken platform, and never throws (R-NOTIFY-003).
  Future<bool> _ensureInitialized() async {
    switch (_initState) {
      case _InitState.ready:
        return true;
      case _InitState.failed:
        return false;
      case _InitState.pending:
        break;
    }
    if (_isWeb) {
      _initState = _InitState.failed;
      return false;
    }
    try {
      const InitializationSettings settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      await _plugin.initialize(settings: settings);
      _initState = _InitState.ready;
      return true;
    } on Object {
      _initState = _InitState.failed;
      return false;
    }
  }

  NotificationDetails _detailsFor() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
      linux: const LinuxNotificationDetails(),
    );
  }

  /// A neutral, content-free title keyed by category. The transport never
  /// receives user content (the port passes only [ReminderCategory]), so no
  /// task/note text is handed to the OS scheduler.
  String _titleFor(ReminderCategory category) => switch (category) {
    ReminderCategory.task => 'Task reminder',
    ReminderCategory.habit => 'Habit reminder',
    ReminderCategory.study => 'Study reminder',
    ReminderCategory.deadline => 'Deadline reminder',
    ReminderCategory.workout => 'Workout reminder',
  };

  String _bodyFor(ReminderCategory category) =>
      'Open Forge to view your ${category.name} reminder.';

  String _encodePayload(ScheduledNotification notification) =>
      jsonEncode(<String, Object?>{
        'r': notification.reminderId,
        'f': notification.fireAtUtc,
        'c': notification.category.wire,
        'a': notification.wantsActions,
      });

  ScheduledNotification? _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final Object? reminderId = decoded['r'];
      final Object? fireAtUtc = decoded['f'];
      final Object? category = decoded['c'];
      if (reminderId is! String || fireAtUtc is! int || category is! String) {
        return null;
      }
      return ScheduledNotification(
        reminderId: reminderId,
        fireAtUtc: fireAtUtc,
        category: ReminderCategory.fromWire(category),
        wantsActions: decoded['a'] == true,
      );
    } on Object {
      return null;
    }
  }

  /// Maps an opaque string reminder id to the plugin's required 32-bit int id,
  /// deterministically across app restarts (FNV-1a folded to a positive 31-bit
  /// value) so [cancel] recomputes the same OS id a later run scheduled.
  int _osId(String reminderId) {
    const int fnvOffset = 0x811c9dc5;
    const int fnvPrime = 0x01000193;
    int hash = fnvOffset;
    for (final int unit in reminderId.codeUnits) {
      hash = (hash ^ unit) & 0xffffffff;
      hash = (hash * fnvPrime) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }
}

enum _InitState { pending, ready, failed }
