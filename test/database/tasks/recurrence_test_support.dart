import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import 'task_test_support.dart';

/// Wiring for real Drift-backed recurrence command/repository tests. Reuses the
/// task command bus so recurrence and task writes share one transactional path.
final class RecurrenceHarness {
  RecurrenceHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.resolver,
    this.tasks,
    this.recurrence,
    this.reads,
  );

  static Future<RecurrenceHarness> open({DateTime? initialUtc}) async {
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
      repositoryFactories: taskRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    final TimeZoneResolver resolver = TimezonePackageResolver.initialized();
    final DriftTaskCommandService tasks = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftRecurrenceCommandService recurrence =
        DriftRecurrenceCommandService(
          bus: bus,
          clock: clock,
          idGenerator: ids,
          timeZoneResolver: resolver,
        );
    return RecurrenceHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId('area-1'),
      clock,
      ids,
      resolver,
      tasks,
      recurrence,
      TaskReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final TimeZoneResolver resolver;
  final DriftTaskCommandService tasks;
  final DriftRecurrenceCommandService recurrence;
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

  Future<List<Map<String, Object?>>> rows(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> result = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return result.map((QueryRow r) => r.data).toList(growable: false);
  }
}
