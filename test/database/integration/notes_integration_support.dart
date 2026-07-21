import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/infrastructure/note_command_service_drift.dart';
import 'package:forge/features/notes/infrastructure/note_read_repository.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';
import 'package:forge/features/planner/infrastructure/planner_command_service_drift.dart';
import 'package:forge/features/planner/infrastructure/planner_repository_factories.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/application/default_task_note_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_note_service.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// End-to-end wiring for task 5.5: one encrypted-schema Drift database shared by
/// the tasks, notes, planner and unified-search feature stacks, plus the
/// application-level [TaskNoteService] that flows a task's notes through the
/// canonical note (R-TASK-010).
///
/// All four search-present projectors that exist in this wave (task + note) are
/// registered into the single [SearchProjectionRegistry] driven in-transaction
/// by the command bus, so a task or note write and its `search_documents`/FTS
/// row advance atomically. This harness composes only exported application
/// contracts across features (design.md §4).
final class NotesIntegrationHarness {
  NotesIntegrationHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.ids,
    required this.tasks,
    required this.taskQuery,
    required this.notes,
    required this.planner,
    required this.taskNotes,
    required this.search,
    required this.noteReads,
  });

  static Future<NotesIntegrationHarness> open({
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
      const <SearchProjector>[TaskSearchProjector(), NoteSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...taskRepositoryFactories,
        ...noteRepositoryFactories,
        ...plannerRepositoryFactories,
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
    final DriftNoteCommandService notes = DriftNoteCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftPlannerCommandService planner = DriftPlannerCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftTaskQueryService taskQuery = DriftTaskQueryService(
      TaskReadRepository(db),
    );
    final DefaultTaskNoteService taskNotes = DefaultTaskNoteService(
      tasks: tasks,
      taskQuery: taskQuery,
      notes: notes,
    );
    return NotesIntegrationHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      ids: ids,
      tasks: tasks,
      taskQuery: taskQuery,
      notes: notes,
      planner: planner,
      taskNotes: taskNotes,
      search: SearchReadRepository(db),
      noteReads: NoteReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftTaskCommandService tasks;
  final DriftTaskQueryService taskQuery;
  final DriftNoteCommandService notes;
  final DriftPlannerCommandService planner;
  final TaskNoteService taskNotes;
  final SearchService search;
  final NoteReadRepository noteReads;

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

  /// Creates a task with [title] and returns its id.
  Future<String> createTask(String title, {String? seed}) async {
    final Result<CommittedCommandResult> result = await tasks.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateTaskInput(lifeAreaId: lifeAreaId, title: title),
    );
    return _id((result as Success<CommittedCommandResult>).value.resultPayload);
  }

  /// Creates a note with [title]/[body] and returns its id.
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
    return _id((result as Success<CommittedCommandResult>).value.resultPayload);
  }

  /// Saves a daily planning record for [periodKey] and returns its period id.
  Future<String> createPlanningPeriod(String periodKey, {String? seed}) async {
    final Result<CommittedCommandResult> result = await planner
        .savePlanningRecord(
          commandId: nextCommandId(seed),
          profileId: profileId,
          input: SavePlanningRecordInput(
            lifeAreaId: lifeAreaId.value,
            kind: PlanningPeriodKind.day,
            periodKey: periodKey,
            morningPlanMd: SectionEdit.set('Plan the day'),
          ),
        );
    final Map<String, Object?> payload =
        jsonDecode(
              (result as Success<CommittedCommandResult>).value.resultPayload!,
            )
            as Map<String, Object?>;
    return payload['period_id'] as String;
  }

  /// Adds a reference from a planning period to an entity and returns the entry
  /// id.
  Future<String> addPlanningReference({
    required String periodId,
    required PlanningReferenceType type,
    required String entityId,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await planner.addReference(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: AddReferenceInput(
        periodId: periodId,
        referenceType: type,
        entityId: entityId,
      ),
    );
    final Map<String, Object?> payload =
        jsonDecode(
              (result as Success<CommittedCommandResult>).value.resultPayload!,
            )
            as Map<String, Object?>;
    return payload['entry_id'] as String;
  }

  static String _id(String? payload) {
    final Object? decoded = jsonDecode(payload!);
    return (decoded as Map<String, Object?>)['id'] as String;
  }
}
