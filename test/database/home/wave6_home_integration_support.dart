import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/composition/forge_search_projectors.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/infrastructure/focus_command_service_drift.dart';
import 'package:forge/features/focus/infrastructure/focus_read_repository.dart';
import 'package:forge/features/focus/infrastructure/focus_repository_factories.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';
import 'package:forge/features/habits/infrastructure/habit_command_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_query_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_repository_factories.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/application/home_query_service.dart';
import 'package:forge/features/home/infrastructure/settings_home_layout_store.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// End-to-end wiring for task 7.5: one encrypted-schema Drift database shared by
/// the tasks, habits, focus, learning, and unified-search stacks, plus the Home
/// query facade composed only from exported application contracts (design.md §4,
/// R-HOME-001..005).
///
/// This proves the Wave 6 integration: Today surfaces the habit checklist, the
/// active study recommendation, and the open focus session alongside tasks, and
/// inline habit check-in / focus start commit durable local state. Every
/// release-present searchable type registers its projector into the single
/// canonical [SearchProjectionRegistry] driven in-transaction by the command
/// bus (R-SEARCH-001).
final class Wave6HomeHarness {
  Wave6HomeHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.ids,
    required this.tasks,
    required this.habits,
    required this.focus,
    required this.learning,
    required this.homeQuery,
    required this.taskQuery,
    required this.habitQuery,
    required this.focusReads,
    required this.learningReads,
    required this.search,
    required this.layoutStore,
  });

  static Future<Wave6HomeHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final FakeMonotonicClock monotonic = FakeMonotonicClock(bootId: 'boot-1');
    final FakeIdGenerator ids = FakeIdGenerator.sequential();

    // The single canonical MVP search registry, wired at the composition root.
    final SearchProjectionRegistry registry = buildForgeSearchRegistry();

    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...taskRepositoryFactories,
        ...noteRepositoryFactories,
        ...habitRepositoryFactories,
        ...focusRepositoryFactories,
        ...learningRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );

    final DriftTaskQueryService taskQuery = DriftTaskQueryService(
      TaskReadRepository(db),
    );
    final DriftHabitQueryService habitQuery = DriftHabitQueryService(db);
    final FocusReadRepository focusReads = FocusReadRepository(db);
    final LearningReadRepository learningReads = LearningReadRepository(db);

    return Wave6HomeHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      ids: ids,
      tasks: DriftTaskCommandService(bus: bus, clock: clock, idGenerator: ids),
      habits: DriftHabitCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      focus: DriftFocusCommandService(
        bus: bus,
        clock: clock,
        monotonic: monotonic,
        idGenerator: ids,
      ),
      learning: DriftLearningCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      // Home composed only from exported application contracts (design.md §4).
      homeQuery: HomeQueryService(
        taskQuery,
        learning: learningReads,
        habits: habitQuery,
        focus: focusReads,
      ),
      taskQuery: taskQuery,
      habitQuery: habitQuery,
      focusReads: focusReads,
      learningReads: learningReads,
      search: SearchReadRepository(db),
      layoutStore: SettingsHomeLayoutStore(db, clock),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftTaskCommandService tasks;
  final DriftHabitCommandService habits;
  final DriftFocusCommandService focus;
  final DriftLearningCommandService learning;
  final HomeQueryService homeQuery;
  final DriftTaskQueryService taskQuery;
  final DriftHabitQueryService habitQuery;
  final FocusReadRepository focusReads;
  final LearningReadRepository learningReads;
  final SearchReadRepository search;
  final SettingsHomeLayoutStore layoutStore;

  int _cmd = 0;
  CommandId nextCommandId([String? seed]) =>
      CommandId('cmd-${seed ?? (_cmd++).toString()}');

  /// The planning day pinned by the fake clock (UTC calendar day).
  String get planningDate {
    final DateTime now = clock.utcNow();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  int get dayStartUtcMicros {
    final DateTime now = clock.utcNow();
    return DateTime.utc(now.year, now.month, now.day).microsecondsSinceEpoch;
  }

  int get nowUtcMicros => clock.utcNow().microsecondsSinceEpoch;

  LocalDate get today {
    final DateTime now = clock.utcNow();
    return LocalDate(now.year, now.month, now.day);
  }

  Future<HomeTodayContent> loadToday({LifeAreaId? lifeAreaId}) =>
      homeQuery.today(
        profileId: profileId,
        currentPlanningDate: planningDate,
        dayStartUtcMicros: dayStartUtcMicros,
        nowUtcMicros: nowUtcMicros,
        lifeAreaId: lifeAreaId,
      );

  // ---- command wrappers ---------------------------------------------------

  Future<String> createTask(
    String title, {
    TaskDue due = TaskDue.none,
    String? scheduledDate,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await tasks.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateTaskInput(
        lifeAreaId: lifeAreaId,
        title: title,
        due: due,
        scheduledDate: scheduledDate,
      ),
    );
    return _id(result);
  }

  /// Creates a daily boolean habit whose first occurrence falls on [today].
  Future<HabitId> createDailyHabit(
    String title, {
    HabitTarget? target,
    String? seed,
  }) async {
    final HabitId habitId = HabitId(seed ?? 'habit-${_cmd++}');
    final Result<CommittedCommandResult> result = await habits.createHabit(
      commandId: nextCommandId('create-$habitId'),
      profileId: profileId,
      habitId: habitId,
      input: CreateHabitInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        rule: HabitScheduleRule(
          frequency: HabitFrequency.daily,
          scheduleKind: HabitScheduleKind.dated,
          start: today,
          timezoneId: 'Etc/UTC',
        ),
        target: target ?? HabitTarget.boolean(),
        rank: 'm',
      ),
    );
    _expectSuccess(result);
    return habitId;
  }

  Future<void> checkInBooleanHabit(HabitId habitId, {String? seed}) async {
    final Result<CommittedCommandResult> result = await habits.checkIn(
      commandId: nextCommandId(seed),
      profileId: profileId,
      habitId: habitId,
      input: CheckInInput(
        onDate: today,
        kind: ObservationInputKind.booleanTrue,
      ),
    );
    _expectSuccess(result);
  }

  /// Starts a count-up focus session and returns its id.
  Future<String> startFocus({LifeAreaId? area, String? seed}) async {
    final Result<CommittedCommandResult> result = await focus.start(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: StartFocusSessionInput(
        lifeAreaId: (area ?? lifeAreaId).value,
        mode: FocusMode.countUp,
      ),
    );
    final CommittedCommandResult r = _expectSuccess(result);
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['session_id']
        as String;
  }

  /// Creates a resource with one incomplete item and a current study session so
  /// the active-study recommendation resolves (R-LEARN-003).
  Future<String> createResumableResource(
    String title, {
    String? creator,
    String? seed,
  }) async {
    final CommittedCommandResult created = _expectSuccess(
      await learning.createResource(
        commandId: nextCommandId(seed),
        profileId: profileId,
        input: CreateResourceInput(
          lifeAreaId: lifeAreaId.value,
          title: title,
          type: LearningResourceType.course,
          creator: creator,
        ),
      ),
    );
    final String resourceId =
        (jsonDecode(created.resultPayload!)
                as Map<String, Object?>)['resource_id']
            as String;
    _expectSuccess(
      await learning.addItem(
        commandId: nextCommandId(),
        profileId: profileId,
        input: AddItemInput(
          resourceId: resourceId,
          title: 'Chapter 1',
          type: LearningItemType.lesson,
        ),
      ),
    );
    _expectSuccess(
      await learning.logStudySession(
        commandId: nextCommandId(),
        profileId: profileId,
        input: LogStudySessionInput(
          resourceId: resourceId,
          startedAtUtc: nowUtcMicros - 3600000000,
          endedAtUtc: nowUtcMicros - 1800000000,
        ),
      ),
    );
    return resourceId;
  }

  Future<void> close() => db.close();

  Future<int> scalar(
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

  static String _id(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r = _expectSuccess(result);
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  static CommittedCommandResult _expectSuccess(
    Result<CommittedCommandResult> result,
  ) {
    return switch (result) {
      Success<CommittedCommandResult>(value: final CommittedCommandResult v) =>
        v,
      Failed<CommittedCommandResult>(failure: final Failure f) =>
        throw StateError(
          'Expected success but got ${f.code}: ${f.redactedCause}',
        ),
    };
  }
}
