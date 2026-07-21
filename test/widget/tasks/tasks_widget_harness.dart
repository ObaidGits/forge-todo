import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import '../../database/schema/schema_test_database.dart';
import '../../database/tasks/task_test_support.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

/// Composes the full tasks presentation stack over a real encrypted-schema
/// Drift database: command, recurrence, deletion, purge-preview and the
/// exported query contract, all sharing one transactional command bus.
final class TasksWidgetHarness {
  TasksWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.commands,
    required this.recurrence,
    required this.deletion,
    required this.preview,
    required this.query,
  });

  static Future<TasksWidgetHarness> open({DateTime? initialUtc}) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: taskRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    final DriftTaskCommandService commands = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftRecurrenceCommandService recurrence =
        DriftRecurrenceCommandService(
          bus: bus,
          clock: clock,
          idGenerator: ids,
          timeZoneResolver: TimezonePackageResolver.initialized(),
        );
    final TrashRegistry registry = TrashRegistry(<TrashableEntity>[
      TrashableEntity(entityType: 'task', tableName: 'tasks'),
    ]);
    final DeletionService deletion = DeletionService(
      bus: bus,
      registry: registry,
      clock: clock,
      idGenerator: ids,
    );
    final PurgePreviewService preview = PurgePreviewService(
      unitOfWork: unitOfWork,
      clock: clock,
      registry: registry,
    );
    return TasksWidgetHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId('area-1'),
      clock: clock,
      commands: commands,
      recurrence: recurrence,
      deletion: deletion,
      preview: preview,
      query: DriftTaskQueryService(TaskReadRepository(db)),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final DriftTaskCommandService commands;
  final DriftRecurrenceCommandService recurrence;
  final DeletionService deletion;
  final PurgePreviewService preview;
  final TaskQueryService query;

  int _commandSeq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_commandSeq++}');

  Future<void> close() => db.close();

  /// Creates a task and returns its generated id.
  Future<String> createTask({
    required String title,
    TaskDue due = TaskDue.none,
    TaskPriority priority = TaskPriority.none,
    String? scheduledDate,
  }) async {
    final Result<CommittedCommandResult> result = await commands.create(
      commandId: nextCommandId(),
      profileId: profileId,
      input: CreateTaskInput(
        lifeAreaId: lifeAreaId,
        title: title,
        due: due,
        priority: priority,
        scheduledDate: scheduledDate,
      ),
    );
    final CommittedCommandResult committed =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(committed.resultPayload!) as Map<String, Object?>)['id']!
        as String;
  }

  Future<void> softDeleteRaw(String taskId) async {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    await db.customStatement(
      'UPDATE tasks SET deleted_at_utc = ? WHERE id = ?',
      <Object?>[now, taskId],
    );
  }

  Future<int> scalar(String sql, [List<Object?> args = const <Object?>[]]) {
    return TaskHarnessSql(db).scalar(sql, args);
  }

  /// Pumps the real Forge router (shell + routes) at [initialLocation] with the
  /// tasks stack wired to this harness.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/tasks',
  }) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = createForgeRouter(initialLocation: initialLocation);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tasksProfileProvider.overrideWithValue(profileId),
          tasksQueryServiceProvider.overrideWithValue(query),
          tasksCommandServiceProvider.overrideWithValue(commands),
          tasksRecurrenceServiceProvider.overrideWithValue(recurrence),
          tasksDeletionServiceProvider.overrideWithValue(deletion),
          tasksPurgePreviewServiceProvider.overrideWithValue(preview),
          tasksClockProvider.overrideWithValue(clock),
          tasksCommandIdFactoryProvider.overrideWithValue(nextCommandId),
          tasksAreaOptionsProvider.overrideWithValue(<TaskAreaOption>[
            TaskAreaOption(id: lifeAreaId, name: 'Career'),
          ]),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// Small SQL helper mirroring [TaskHarness] scalar access without exposing the
/// whole harness type here.
final class TaskHarnessSql {
  TaskHarnessSql(this._db);
  final ForgeSchemaDatabase _db;

  Future<int> scalar(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data.values.first as int;
  }
}
