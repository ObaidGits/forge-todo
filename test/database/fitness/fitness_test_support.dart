import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/application/water_tracking_settings.dart';
import 'package:forge/features/fitness/infrastructure/fitness_command_service_drift.dart';
import 'package:forge/features/fitness/infrastructure/fitness_query_service_drift.dart';
import 'package:forge/features/fitness/infrastructure/fitness_read_repository.dart';
import 'package:forge/features/fitness/infrastructure/fitness_repository_factories.dart';
import 'package:forge/features/fitness/infrastructure/settings_water_tracking_store.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed fitness command/repository tests.
final class FitnessHarness {
  FitnessHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.service,
    this.queries,
    this.waterSettings,
  );

  static Future<FitnessHarness> open({DateTime? initialUtc}) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: fitnessRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    final WaterTrackingSettings waterSettings = SettingsWaterTrackingStore(
      db,
      clock,
    );
    final DriftFitnessCommandService service = DriftFitnessCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
      waterTracking: waterSettings,
    );
    return FitnessHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId('area-1'),
      clock,
      ids,
      service,
      DriftFitnessQueryService(FitnessReadRepository(db), waterSettings),
      waterSettings,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftFitnessCommandService service;
  final DriftFitnessQueryService queries;
  final WaterTrackingSettings waterSettings;

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
