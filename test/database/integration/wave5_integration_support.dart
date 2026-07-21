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
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_read_repository.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/roadmap_read_repository.dart';
import 'package:forge/features/goals/infrastructure/roadmap_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
import 'package:forge/features/home/application/home_query_service.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/infrastructure/note_command_service_drift.dart';
import 'package:forge/features/notes/infrastructure/note_read_repository.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// End-to-end wiring for task 6.5: one encrypted-schema Drift database shared by
/// the tasks, notes, goals, roadmap, learning, and unified-search feature
/// stacks, plus the Home query facade composed only from exported application
/// contracts (design.md §4).
///
/// Every release-present searchable type in this wave (task, note, goal,
/// roadmap topic, Learning Resource) registers its projector into the single
/// [SearchProjectionRegistry] driven in-transaction by the command bus, so a
/// domain write and its `search_documents`/FTS row advance atomically
/// (R-SEARCH-001). The Home facade consumes the learning feature's exported
/// resume contract to surface the Today study recommendation without mutating
/// it (R-HOME-001, R-LEARN-003).
final class Wave5IntegrationHarness {
  Wave5IntegrationHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.ids,
    required this.tasks,
    required this.notes,
    required this.goals,
    required this.roadmaps,
    required this.learning,
    required this.taskQuery,
    required this.homeQuery,
    required this.goalReads,
    required this.roadmapReads,
    required this.learningReads,
    required this.noteReads,
    required this.search,
  });

  static Future<Wave5IntegrationHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry =
        SearchProjectionRegistry(const <SearchProjector>[
          TaskSearchProjector(),
          NoteSearchProjector(),
          GoalSearchProjector(),
          RoadmapTopicSearchProjector(),
          LearningSearchProjector(),
        ]);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...taskRepositoryFactories,
        ...noteRepositoryFactories,
        ...goalRepositoryFactories,
        ...roadmapRepositoryFactories,
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
    final DriftTaskCommandService tasks = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftTaskQueryService taskQuery = DriftTaskQueryService(
      TaskReadRepository(db),
    );
    final LearningReadRepository learningReads = LearningReadRepository(db);
    return Wave5IntegrationHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      ids: ids,
      tasks: tasks,
      notes: DriftNoteCommandService(bus: bus, clock: clock, idGenerator: ids),
      goals: DriftGoalCommandService(bus: bus, clock: clock, idGenerator: ids),
      roadmaps: DriftRoadmapCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      learning: DriftLearningCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      taskQuery: taskQuery,
      homeQuery: HomeQueryService(taskQuery, learning: learningReads),
      goalReads: GoalReadRepository(db),
      roadmapReads: RoadmapReadRepository(db),
      learningReads: learningReads,
      noteReads: NoteReadRepository(db),
      search: SearchReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftTaskCommandService tasks;
  final DriftNoteCommandService notes;
  final DriftGoalCommandService goals;
  final DriftRoadmapCommandService roadmaps;
  final DriftLearningCommandService learning;
  final DriftTaskQueryService taskQuery;
  final HomeQueryService homeQuery;
  final GoalReadRepository goalReads;
  final RoadmapReadRepository roadmapReads;
  final LearningReadRepository learningReads;
  final NoteReadRepository noteReads;
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

  // ---- command wrappers ---------------------------------------------------

  Future<String> createTask(String title, {String? seed}) async {
    final Result<CommittedCommandResult> result = await tasks.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateTaskInput(lifeAreaId: lifeAreaId, title: title),
    );
    return _id(result);
  }

  Future<String> createNote(
    String title, {
    String body = '',
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await notes.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateNoteInput(lifeAreaId: lifeAreaId, title: title, body: body),
    );
    return _id(result);
  }

  Future<String> createGoal(String title, {String? seed}) async {
    final Result<CommittedCommandResult> result = await goals.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateGoalInput(lifeAreaId: lifeAreaId, title: title),
    );
    return _id(result);
  }

  Future<String> createRoadmap(String goalId, {String? seed}) async {
    final Result<CommittedCommandResult> result = await roadmaps.createRoadmap(
      commandId: nextCommandId(seed),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: const CreateRoadmapInput(title: 'Path'),
    );
    return _id(result);
  }

  Future<String> addSection(String roadmapId, {String? seed}) async {
    final Result<CommittedCommandResult> result = await roadmaps.addSection(
      commandId: nextCommandId(seed),
      profileId: profileId,
      roadmapId: RoadmapId(roadmapId),
      input: const CreateSectionInput(title: 'Section'),
    );
    return _id(result);
  }

  Future<String> addTopic(
    String sectionId,
    String title, {
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.addTopic(
      commandId: nextCommandId(seed),
      profileId: profileId,
      sectionId: RoadmapSectionId(sectionId),
      input: CreateTopicInput(title: title),
    );
    return _id(result);
  }

  Future<String> createResource(
    String title, {
    LearningResourceType type = LearningResourceType.course,
    String? creator,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await learning.createResource(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateResourceInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        type: type,
        creator: creator,
      ),
    );
    return _idKey(result, 'resource_id');
  }

  Future<String> addItem(
    String resourceId,
    String title, {
    LearningItemType type = LearningItemType.lesson,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await learning.addItem(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: AddItemInput(resourceId: resourceId, title: title, type: type),
    );
    return _idKey(result, 'item_id');
  }

  Future<void> completeItem(
    String itemId, {
    required int at,
    String? seed,
  }) async {
    await learning.completeItem(
      commandId: nextCommandId(seed),
      profileId: profileId,
      itemId: itemId,
      completedAtUtc: at,
    );
  }

  Future<void> logStudySession(
    String resourceId, {
    required int startedAtUtc,
    required int endedAtUtc,
    String? itemId,
    String? seed,
  }) async {
    await learning.logStudySession(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: LogStudySessionInput(
        resourceId: resourceId,
        startedAtUtc: startedAtUtc,
        endedAtUtc: endedAtUtc,
        itemId: itemId,
      ),
    );
  }

  Future<void> linkNoteTo(
    String noteId,
    String targetType,
    String targetId, {
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await notes.linkEntity(
      commandId: nextCommandId(seed),
      profileId: profileId,
      noteId: NoteId(noteId),
      targetType: targetType,
      targetId: targetId,
    );
    // Surface a failure as a test error with the stable code.
    if (result is Failed<CommittedCommandResult>) {
      throw StateError('linkEntity failed: ${result.failure.code}');
    }
  }

  Future<void> linkTopicToNote(
    String topicId,
    String targetType,
    String targetId, {
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps
        .linkTopicEntity(
          commandId: nextCommandId(seed),
          profileId: profileId,
          topicId: RoadmapTopicId(topicId),
          input: LinkTopicEntityInput(
            targetType: targetType,
            targetId: targetId,
          ),
        );
    if (result is Failed<CommittedCommandResult>) {
      throw StateError('linkTopicEntity failed: ${result.failure.code}');
    }
  }

  static String _id(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  static String _idKey(Result<CommittedCommandResult> result, String key) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)[key]
        as String;
  }
}
