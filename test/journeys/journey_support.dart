import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/application/home_query_service.dart';
import 'package:forge/features/tasks/application/recurrence_commands.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';

import '../database/schema/schema_test_database.dart';
import '../database/tasks/task_test_support.dart';
import '../helpers/fake_clock.dart';
import '../helpers/fake_id_generator.dart';

/// End-to-end journey harness that drives the *real* Wave 3 daily-use loop —
/// the task command service, the tasks query contract, and the Home/Today
/// query facade — over a genuine on-disk SQLite database.
///
/// Unlike the in-memory unit harnesses, this harness can [restart]: it closes
/// the database and reopens a brand-new stack over the same file, proving that
/// committed work survives a process kill/reopen and that provider state is
/// never the source of truth (R-GEN-001).
final class JourneyApp {
  JourneyApp._(
    this._file,
    this._db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
  ) : _stack = _Stack.build(_db, profileId.value);

  final String _file;
  ForgeSchemaDatabase _db;
  _Stack _stack;

  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;

  /// Opens a fresh on-disk store with one active profile and one Life Area,
  /// modelling a first offline launch.
  static Future<JourneyApp> launch({
    required String file,
    DateTime? initialUtc,
  }) async {
    final ForgeSchemaDatabase db = ForgeSchemaDatabase(
      NativeDatabase(File(file)),
    );
    const String profileId = 'profile-1';
    const String areaId = 'area-1';
    await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    return JourneyApp._(
      file,
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
    );
  }

  /// Simulates a hard kill and relaunch: the database connection is closed and
  /// a completely new command/query stack is opened over the same file.
  Future<void> restart() async {
    await _db.close();
    _db = ForgeSchemaDatabase(NativeDatabase(File(_file)));
    _stack = _Stack.build(_db, profileId.value);
  }

  Future<String> quickCapture(String title, {String seed = 'capture'}) async {
    // Title-only quick capture: an Inbox task with no date (R-TASK-001).
    return _create(seed: seed, title: title);
  }

  Future<String> createDueToday(String title, {String seed = 'due'}) {
    return _create(seed: seed, title: title, due: TaskDue.onDate(_todayIso));
  }

  Future<String> _create({
    required String seed,
    required String title,
    TaskDue due = TaskDue.none,
    TaskPriority priority = TaskPriority.none,
  }) async {
    final Result<CommittedCommandResult> result = await _stack.commands.create(
      commandId: CommandId('cmd-$seed'),
      profileId: profileId,
      input: CreateTaskInput(
        lifeAreaId: lifeAreaId,
        title: title,
        due: due,
        priority: priority,
      ),
    );
    return _idOf(result);
  }

  Future<CommittedCommandResult> complete(
    String taskId, {
    String seed = 'complete',
  }) async {
    final Result<CommittedCommandResult> result = await _stack.commands
        .complete(
          commandId: CommandId('cmd-$seed'),
          profileId: profileId,
          taskId: TaskId(taskId),
        );
    return (result as Success<CommittedCommandResult>).value;
  }

  Future<void> setRecurrence(
    String taskId,
    RecurrenceRule rule, {
    String seed = 'set',
  }) async {
    final Result<CommittedCommandResult> result = await _stack.recurrence
        .setRecurrence(
          commandId: CommandId('cmd-$seed'),
          profileId: profileId,
          taskId: TaskId(taskId),
          input: SetRecurrenceInput(rule: rule),
        );
    (result as Success<CommittedCommandResult>).value;
  }

  Future<CommittedCommandResult> completeOccurrence(
    String taskId, {
    String seed = 'occ',
  }) async {
    final Result<CommittedCommandResult> result = await _stack.recurrence
        .completeOccurrence(
          commandId: CommandId('cmd-$seed'),
          profileId: profileId,
          taskId: TaskId(taskId),
        );
    return (result as Success<CommittedCommandResult>).value;
  }

  Future<CommittedCommandResult> editRecurrenceThisAndFuture(
    String taskId, {
    required RecurrenceRule newRule,
    required LocalDate fromKey,
    String seed = 'edit',
  }) async {
    final Result<CommittedCommandResult> result = await _stack.recurrence
        .editRecurrence(
          commandId: CommandId('cmd-$seed'),
          profileId: profileId,
          taskId: TaskId(taskId),
          input: EditRecurrenceInput(
            scope: RecurrenceEditScope.thisAndFuture,
            fromOccurrenceKey: fromKey,
            newRule: newRule,
          ),
        );
    return (result as Success<CommittedCommandResult>).value;
  }

  Future<HomeTodayContent> today() {
    final DateTime now = clock.utcNow();
    return _stack.home.today(
      profileId: profileId,
      currentPlanningDate: _todayIso,
      dayStartUtcMicros: DateTime.utc(
        now.year,
        now.month,
        now.day,
      ).microsecondsSinceEpoch,
      nowUtcMicros: now.microsecondsSinceEpoch,
    );
  }

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

  Future<void> close() => _db.close();

  String get _todayIso {
    final DateTime now = clock.utcNow();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static String _idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult committed =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(committed.resultPayload!) as Map<String, Object?>)['id']!
        as String;
  }
}

/// The composed command/query stack over one open database generation.
final class _Stack {
  _Stack(this.commands, this.recurrence, this.home);

  factory _Stack.build(ForgeSchemaDatabase db, String profileId) {
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 15, 9));
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
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
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
    final DriftTaskQueryService query = DriftTaskQueryService(
      TaskReadRepository(db),
    );
    return _Stack(commands, recurrence, HomeQueryService(query));
  }

  final DriftTaskCommandService commands;
  final DriftRecurrenceCommandService recurrence;
  final HomeQueryService home;
}
