import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/infrastructure/focus_command_service_drift.dart';
import 'package:forge/features/focus/infrastructure/focus_read_repository.dart';
import 'package:forge/features/focus/infrastructure/focus_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed focus tests: the focus command service over an
/// in-memory (or supplied file-backed) store, with deterministic wall and
/// monotonic clocks so timer truth can be exercised across reboots and clock
/// discontinuities (R-FOCUS-002).
final class FocusHarness {
  FocusHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.monotonic,
    this.ids,
    this.service,
    this.reads,
  );

  static Future<FocusHarness> open({
    ForgeSchemaDatabase? database,
    DateTime? initialUtc,
    Duration monotonicInitial = Duration.zero,
    String bootId = 'boot-1',
    String areaId = 'area-1',
    bool freshProfile = true,
    bool secondArea = false,
    int idStart = 1,
  }) async {
    final ForgeSchemaDatabase db = database ?? openSchemaDatabase();
    const String profileId = 'profile-1';
    if (freshProfile) {
      await insertProfile(db);
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
    }
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    final FakeMonotonicClock monotonic = FakeMonotonicClock(
      initial: monotonicInitial,
      bootId: bootId,
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential(start: idStart);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: focusRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    final DriftFocusCommandService service = DriftFocusCommandService(
      bus: bus,
      clock: clock,
      monotonic: monotonic,
      idGenerator: ids,
    );
    return FocusHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      monotonic,
      ids,
      service,
      FocusReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeMonotonicClock monotonic;
  final FakeIdGenerator ids;
  final DriftFocusCommandService service;
  final FocusReadRepository reads;

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

  /// Starts a session and returns its id.
  Future<String> start({
    required StartFocusSessionInput input,
    String? seed,
  }) async {
    final CommittedCommandResult r = expectSuccess(
      await service.start(
        commandId: nextCommandId(seed),
        profileId: profileId,
        input: input,
      ),
    );
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['session_id']
        as String;
  }
}
