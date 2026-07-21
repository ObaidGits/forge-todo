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
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/roadmap_read_repository.dart';
import 'package:forge/features/goals/infrastructure/roadmap_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
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

/// Wiring for real Drift-backed roadmap tests: goal + roadmap command services
/// sharing one command bus with the in-transaction search coordinator (task +
/// note + goal + roadmap-topic projectors), plus the roadmap and search read
/// models. A note command service is included so canonical-note references can
/// be exercised end to end.
final class RoadmapHarness {
  RoadmapHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.goals,
    this.roadmaps,
    this.notes,
    this.reads,
    this.search,
  );

  static Future<RoadmapHarness> open({
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
    final SearchProjectionRegistry registry =
        SearchProjectionRegistry(const <SearchProjector>[
          TaskSearchProjector(),
          NoteSearchProjector(),
          GoalSearchProjector(),
          RoadmapTopicSearchProjector(),
        ]);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...goalRepositoryFactories,
        ...roadmapRepositoryFactories,
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
    return RoadmapHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      DriftGoalCommandService(bus: bus, clock: clock, idGenerator: ids),
      DriftRoadmapCommandService(bus: bus, clock: clock, idGenerator: ids),
      DriftNoteCommandService(bus: bus, clock: clock, idGenerator: ids),
      RoadmapReadRepository(db),
      SearchReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftGoalCommandService goals;
  final DriftRoadmapCommandService roadmaps;
  final DriftNoteCommandService notes;
  final RoadmapReadRepository reads;
  final SearchReadRepository search;

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

  String idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  // ---- convenience builders ----------------------------------------------

  Future<String> createGoal({
    String title = 'Learn Rust',
    GoalProgressMode progressMode = GoalProgressMode.derived,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await goals.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateGoalInput(
        lifeAreaId: lifeAreaId,
        title: title,
        progressMode: progressMode,
        manualProgress: progressMode == GoalProgressMode.manual ? 0.0 : null,
      ),
    );
    return idOf(result);
  }

  Future<String> createRoadmap(
    String goalId, {
    String title = 'Path',
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.createRoadmap(
      commandId: nextCommandId(seed),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: CreateRoadmapInput(title: title),
    );
    return idOf(result);
  }

  Future<String> addSection(
    String roadmapId, {
    String title = 'Section',
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.addSection(
      commandId: nextCommandId(seed),
      profileId: profileId,
      roadmapId: RoadmapId(roadmapId),
      input: CreateSectionInput(title: title),
    );
    return idOf(result);
  }

  Future<String> addTopic(
    String sectionId, {
    String title = 'Topic',
    RoadmapTopicStatus status = RoadmapTopicStatus.open,
    num? weight,
    int? estimateSec,
    NoteId? noteId,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.addTopic(
      commandId: nextCommandId(seed),
      profileId: profileId,
      sectionId: RoadmapSectionId(sectionId),
      input: CreateTopicInput(
        title: title,
        status: status,
        weight: weight,
        estimateSec: estimateSec,
        noteId: noteId,
      ),
    );
    return idOf(result);
  }

  Future<String> addChecklistItem(
    String topicId, {
    String text = 'Step',
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps
        .addChecklistItem(
          commandId: nextCommandId(seed),
          profileId: profileId,
          topicId: RoadmapTopicId(topicId),
          input: CreateChecklistItemInput(text: text),
        );
    return idOf(result);
  }

  Future<void> setTopicStatus(
    String topicId,
    RoadmapTopicStatus status, {
    String? seed,
  }) async {
    await roadmaps.setTopicStatus(
      commandId: nextCommandId(seed),
      profileId: profileId,
      topicId: RoadmapTopicId(topicId),
      status: status,
    );
  }

  Future<String> createNote({String title = 'Topic note', String? seed}) async {
    final Result<CommittedCommandResult> result = await notes.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateNoteInput(lifeAreaId: lifeAreaId, title: title),
    );
    return idOf(result);
  }
}
