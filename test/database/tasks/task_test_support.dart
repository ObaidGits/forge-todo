import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';

/// Wiring for real Drift-backed task command/repository tests.
final class TaskHarness {
  TaskHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.service,
    this.reads,
  );

  static Future<TaskHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    // Deterministic but abundant id supply for tasks, activity, outbox, groups.
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
    final DriftTaskCommandService service = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    return TaskHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      service,
      TaskReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftTaskCommandService service;
  final TaskReadRepository reads;

  CommandId nextCommandId(String seed) => CommandId('cmd-$seed');

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
}

/// Inserts a life area for [profileId] and returns its id.
Future<String> insertLifeArea(
  ForgeSchemaDatabase db,
  String profileId, {
  String id = 'area-1',
  String normalizedName = 'career',
  bool isDefault = true,
}) async {
  await db.customStatement(
    'INSERT INTO life_areas '
    '(id, profile_id, name, normalized_name, rank, is_default, '
    'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      profileId,
      'Career',
      normalizedName,
      'm',
      isDefault ? 1 : 0,
      0,
      0,
    ],
  );
  return id;
}
