import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed learning tests: the learning command service
/// with the in-transaction search coordinator (the learning projector), the
/// learning read model, and the unified search read model.
final class LearningHarness {
  LearningHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.service,
    this.reads,
    this.search,
    this.registry,
  );

  static Future<LearningHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
    bool secondArea = false,
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    if (secondArea) {
      await insertLifeArea(
        db,
        profileId,
        id: 'area-2',
        normalizedName: 'health',
        isDefault: false,
      );
    }
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <SearchProjector>[LearningSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
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
    final DriftLearningCommandService service = DriftLearningCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    return LearningHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      service,
      LearningReadRepository(db),
      SearchReadRepository(db),
      registry,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftLearningCommandService service;
  final LearningReadRepository reads;
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

  // ---- convenience command wrappers ---------------------------------------

  Future<String> createResource({
    String title = 'Flutter in Action',
    LearningResourceType type = LearningResourceType.book,
    String? creator,
    String? sourceUri,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await service.createResource(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateResourceInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        type: type,
        creator: creator,
        sourceUri: sourceUri,
      ),
    );
    return _idFrom(result, 'resource_id');
  }

  Future<String> addItem(
    String resourceId, {
    String title = 'Chapter',
    LearningItemType type = LearningItemType.lesson,
    String? parentId,
    int? durationSec,
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await service.addItem(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: AddItemInput(
        resourceId: resourceId,
        title: title,
        type: type,
        parentId: parentId,
        durationSec: durationSec,
      ),
    );
    return _idFrom(result, 'item_id');
  }

  CommittedCommandResult expectSuccess(Result<CommittedCommandResult> result) {
    return switch (result) {
      Success<CommittedCommandResult>(value: final CommittedCommandResult v) =>
        v,
      Failed<CommittedCommandResult>(failure: final Failure f) =>
        throw StateError(
          'Expected success but got ${f.code}: ${f.redactedCause}',
        ),
    };
  }

  String _idFrom(Result<CommittedCommandResult> result, String key) {
    final CommittedCommandResult r = expectSuccess(result);
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)[key]
        as String;
  }
}
