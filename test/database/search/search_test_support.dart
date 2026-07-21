import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/infrastructure/search_index_maintenance.dart';
import 'package:forge/features/search/infrastructure/search_projection_reconciler.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed unified-search tests: task command service with
/// the in-transaction search coordinator, plus the search read model, index
/// maintenance and reconciler.
final class SearchHarness {
  SearchHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.tasks,
    this.search,
    this.reads,
    this.registry,
    this.maintenance,
    this.reconciler,
  );

  static Future<SearchHarness> open({
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
      const <TaskSearchProjector>[TaskSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...taskRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    final DriftTaskCommandService taskService = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final SearchReadRepository reads = SearchReadRepository(db);
    return SearchHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      taskService,
      reads,
      reads,
      registry,
      SearchIndexMaintenance(
        db: db,
        unitOfWork: unitOfWork,
        registry: registry,
        clock: clock,
      ),
      SearchProjectionReconciler(
        db: db,
        unitOfWork: unitOfWork,
        registry: registry,
        clock: clock,
      ),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftTaskCommandService tasks;
  final SearchService search;
  final SearchReadRepository reads;
  final SearchProjectionRegistry registry;
  final SearchIndexMaintenance maintenance;
  final SearchProjectionReconciler reconciler;

  int cmd = 0;

  Future<void> close() => db.close();

  /// Creates a task with [title] and returns its id.
  Future<String> createTask(String title, {String? parentTaskId}) async {
    final result = await tasks.create(
      commandId: CommandId('cmd-${cmd++}'),
      profileId: profileId,
      input: CreateTaskInput(
        lifeAreaId: lifeAreaId,
        title: title,
        parentTaskId: parentTaskId == null ? null : TaskId(parentTaskId),
      ),
    );
    return result.valueOrNull!.resultPayload!
        .replaceAll(RegExp(r'.*"id":"'), '')
        .replaceAll('"}', '');
  }

  Future<void> updateTitle(String taskId, String title) async {
    await tasks.update(
      commandId: CommandId('cmd-${cmd++}'),
      profileId: profileId,
      taskId: TaskId(taskId),
      input: UpdateTaskInput(title: title),
    );
  }

  Future<void> completeTask(String taskId) async {
    await tasks.complete(
      commandId: CommandId('cmd-${cmd++}'),
      profileId: profileId,
      taskId: TaskId(taskId),
    );
  }

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

  /// Soft-deletes a task row directly (simulating the deletion service) so the
  /// projector tombstones it on the next search marker.
  Future<void> softDeleteRow(String taskId, {required int atUtc}) async {
    await db.customStatement(
      'UPDATE tasks SET deleted_at_utc = ? WHERE id = ?',
      <Object?>[atUtc, taskId],
    );
  }
}
