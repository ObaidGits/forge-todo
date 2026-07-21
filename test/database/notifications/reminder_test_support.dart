import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';
import 'package:forge/features/notifications/infrastructure/horizon_reminder_scheduler.dart';
import 'package:forge/features/notifications/infrastructure/reminder_command_service_drift.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repositories.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../../helpers/fake_scheduler.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// One shared, initialized IANA resolver for all reminder tests (deterministic
/// pinned timezone database).
final TimeZoneResolver sharedResolver = TimezonePackageResolver.initialized();

/// A [NotificationTransport] backed by the shared [FakeScheduler] and
/// [FakeBackgroundScheduler] test fakes, so no reminder test depends on a real
/// plugin (design §9). Capability and permission are directly controllable so
/// diagnostics and the R-NOTIFY-004 lifecycle triggers can be exercised.
final class FakeNotificationTransport implements NotificationTransport {
  FakeNotificationTransport({SchedulerCapability? capability})
    : _capability = capability ?? SchedulerCapability.fullyCapable() {
    _scheduler.setPermission(
      _capability.permission.isGranted
          ? FakeSchedulerPermission.granted
          : FakeSchedulerPermission.denied,
    );
  }

  final FakeScheduler<String> _scheduler = FakeScheduler<String>();
  final FakeBackgroundScheduler background = FakeBackgroundScheduler();
  SchedulerCapability _capability;
  PermissionStatus? _requestResult;
  final Set<String> failReminderIds = <String>{};
  int requestCount = 0;

  void setCapability(SchedulerCapability capability) {
    _capability = capability;
    _scheduler.setPermission(
      capability.permission.isGranted
          ? FakeSchedulerPermission.granted
          : FakeSchedulerPermission.denied,
    );
  }

  void grantOnRequest(PermissionStatus status) => _requestResult = status;

  @override
  Future<SchedulerCapability> capability() async => _capability;

  @override
  Future<PermissionStatus> requestPermission() async {
    requestCount += 1;
    final PermissionStatus status = _requestResult ?? PermissionStatus.granted;
    setCapability(
      SchedulerCapability(
        permission: status,
        available: _capability.available,
        exactAlarms: _capability.exactAlarms,
        actionsSupported: _capability.actionsSupported,
        pendingQuota: _capability.pendingQuota,
        evidenceId: _capability.evidenceId,
      ),
    );
    return status;
  }

  @override
  Future<List<ScheduledNotification>> pending() async {
    return _scheduler.scheduled
        .map(
          (ScheduledItem<String> item) => ScheduledNotification(
            reminderId: item.id,
            fireAtUtc: item.dueAtUtc.microsecondsSinceEpoch,
            category: ReminderCategory.fromWire(item.payload),
            wantsActions: _capability.actionsSupported,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    if (failReminderIds.contains(notification.reminderId)) {
      throw NotificationTransportException(
        'injected failure for ${notification.reminderId}',
      );
    }
    try {
      await _scheduler.schedule(
        ScheduledItem<String>(
          id: notification.reminderId,
          dueAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            notification.fireAtUtc,
            isUtc: true,
          ),
          payload: notification.category.wire,
        ),
      );
    } on StateError catch (error) {
      throw NotificationTransportException(error.message);
    }
  }

  @override
  Future<bool> cancel(String reminderId) => _scheduler.cancel(reminderId);
}

/// Full wiring for real Drift-backed reminder tests.
final class ReminderHarness {
  ReminderHarness._(
    this.db,
    this.profileId,
    this.clock,
    this.ids,
    this.commands,
    this.reads,
    this.transport,
    this.scheduler,
    this.service,
    this.tasks,
  );

  static Future<ReminderHarness> open({
    DateTime? initialUtc,
    String timezoneId = 'Etc/UTC',
    SchedulerCapability? capability,
    NotificationSettingsStore? settingsStore,
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
      timezoneIdentifier: timezoneId,
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...reminderRepositoryFactories,
        ...taskRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    final DriftReminderCommandService commands = DriftReminderCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftTaskCommandService tasks = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final ReminderReadRepositoryDrift reads = ReminderReadRepositoryDrift(db);
    final FakeNotificationTransport transport = FakeNotificationTransport(
      capability: capability,
    );
    final HorizonReminderScheduler scheduler = HorizonReminderScheduler(
      transport,
    );
    return ReminderHarness._(
      db,
      ProfileId(profileId),
      clock,
      ids,
      commands,
      reads,
      transport,
      scheduler,
      ReminderService(
        reads: reads,
        scheduler: scheduler,
        transport: transport,
        resolver: sharedResolver,
        clock: clock,
        settingsStore:
            settingsStore ?? const DefaultNotificationSettingsStore(),
        projection: reads,
      ),
      tasks,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftReminderCommandService commands;
  final ReminderReadRepositoryDrift reads;
  final FakeNotificationTransport transport;
  final HorizonReminderScheduler scheduler;
  final ReminderService service;
  final DriftTaskCommandService tasks;

  CommandId cmd(String seed) => CommandId('cmd-$seed');

  ReminderId rid(String seed) => ReminderId('rem-$seed');

  Future<void> close() => db.close();

  Future<int> scalarInt(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data.values.first as int;
  }

  Future<Map<String, Object?>?> firstRow(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  /// Inserts a minimal open task and returns its id.
  Future<String> insertTask({
    String id = 'task-1',
    String title = 'Task',
    int? dueAtUtc,
    String? dueTimezone,
  }) async {
    await db.customStatement(
      'INSERT INTO tasks '
      '(id, profile_id, life_area_id, title, status, priority, rank, '
      'due_at_utc, due_timezone, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        profileId.value,
        'area-1',
        title,
        'open',
        'none',
        'm',
        dueAtUtc,
        dueTimezone,
        0,
        0,
      ],
    );
    return id;
  }
}
