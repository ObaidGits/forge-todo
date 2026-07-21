import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';
import 'package:forge/features/notifications/infrastructure/local_notifications_transport.dart';

/// Failure-degradation contract for the production transport (R-NOTIFY-003).
///
/// These exercise the transport on a platform where no notification scheduler
/// is available (the web/unsupported seam), which is the same code path a real
/// desktop takes when initialization fails or no notification daemon is
/// present. The contract: a plugin exception must NEVER escape — capability()
/// degrades honestly, reads return empty, cancel is a benign no-op, and only
/// schedule() surfaces a mapped [NotificationTransportException] so the horizon
/// reconciler can record a diagnostic instead of crashing.
void main() {
  LocalNotificationsTransport buildUnavailableTransport() =>
      LocalNotificationsTransport(
        // The unsupported/web seam short-circuits initialization before any
        // platform channel call, so no real plugin/daemon is required.
        isWebOverride: true,
        platformOverride: TargetPlatform.linux,
      );

  group('LocalNotificationsTransport failure degradation', () {
    test(
      'capability() reports an unavailable, cannot-schedule snapshot',
      () async {
        final LocalNotificationsTransport transport =
            buildUnavailableTransport();

        final SchedulerCapability capability = await transport.capability();

        expect(capability.available, isFalse);
        expect(capability.canSchedule, isFalse);
        expect(capability.exactAlarms, isFalse);
        expect(capability.actionsSupported, isFalse);
        expect(capability.evidenceId, isNotNull);
      },
    );

    test(
      'requestPermission() degrades to denied instead of throwing',
      () async {
        final LocalNotificationsTransport transport =
            buildUnavailableTransport();

        expect(await transport.requestPermission(), PermissionStatus.denied);
      },
    );

    test('pending() returns an empty set without throwing', () async {
      final LocalNotificationsTransport transport = buildUnavailableTransport();

      expect(await transport.pending(), isEmpty);
    });

    test('cancel() is a benign no-op returning false', () async {
      final LocalNotificationsTransport transport = buildUnavailableTransport();

      expect(await transport.cancel('rem-1'), isFalse);
    });

    test('schedule() maps unavailability to NotificationTransportException, '
        'never a raw plugin exception', () async {
      final LocalNotificationsTransport transport = buildUnavailableTransport();

      await expectLater(
        transport.schedule(
          const ScheduledNotification(
            reminderId: 'rem-1',
            fireAtUtc: 1000,
            category: ReminderCategory.task,
            wantsActions: true,
          ),
        ),
        throwsA(isA<NotificationTransportException>()),
      );
    });
  });
}
