import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_read_repository.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/infrastructure/note_command_service_drift.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed goal tests: the goal command service with the
/// in-transaction search coordinator (task + note + goal projectors), the goal
/// read model, the unified search read model, and a note command service so
/// canonical-note reference behaviour can be exercised end to end.
final class GoalHarness {
  GoalHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.goals,
    this.notes,
    this.reads,
    this.search,
    this.registry,
  );

  static Future<GoalHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <SearchProjector>[
        TaskSearchProjector(),
        NoteSearchProjector(),
        GoalSearchProjector(),
      ],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...goalRepositoryFactories,
        ...noteRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    final DriftGoalCommandService goals = DriftGoalCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftNoteCommandService notes = DriftNoteCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    return GoalHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      goals,
      notes,
      GoalReadRepository(db),
      SearchReadRepository(db),
      registry,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftGoalCommandService goals;
  final DriftNoteCommandService notes;
  final GoalReadRepository reads;
  final SearchReadRepository search;
  final SearchProjectionRegistry registry;

  int _cmd = 0;
  CommandId nextCommandId([String? seed]) =>
      CommandId('cmd-${seed ?? (_cmd++).toString()}');

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

  String _idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  /// Creates a goal and returns its id.
  Future<String> createGoal({
    String title = 'Learn Rust',
    String outcomeMd = '',
    GoalStatus status = GoalStatus.active,
    String? targetDate,
    GoalProgressMode progressMode = GoalProgressMode.manual,
    double? manualProgress = 0.0,
    NoteId? noteId,
    List<String> tagIds = const <String>[],
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await goals.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateGoalInput(
        lifeAreaId: lifeAreaId,
        title: title,
        outcomeMd: outcomeMd,
        status: status,
        targetDate: targetDate,
        progressMode: progressMode,
        manualProgress: progressMode == GoalProgressMode.derived
            ? null
            : manualProgress,
        noteId: noteId,
        tagIds: tagIds,
      ),
    );
    return _idOf(result);
  }

  /// Adds a milestone to [goalId] and returns its id.
  Future<String> addMilestone(
    String goalId, {
    String title = 'Finish chapter 1',
    String? targetDate,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await goals.addMilestone(
      commandId: nextCommandId(seed),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: CreateMilestoneInput(title: title, targetDate: targetDate),
    );
    return _idOf(result);
  }

  /// Creates a canonical note and returns its id (for note-reference tests).
  Future<String> createNote({String title = 'Goal note', String? seed}) async {
    final Result<CommittedCommandResult> result = await notes.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateNoteInput(lifeAreaId: lifeAreaId, title: title),
    );
    return _idOf(result);
  }

  /// Creates a second (inactive) profile with its own life area and returns its
  /// profile id, for cross-profile ownership tests.
  Future<String> insertForeignProfile({
    String id = 'profile-2',
    String areaId = 'area-2',
  }) async {
    await insertProfile(db, id: id, isActive: false);
    await insertLifeArea(db, id, id: areaId, normalizedName: 'career-2');
    return id;
  }
}
