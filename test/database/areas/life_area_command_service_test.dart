import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';
import 'package:forge/features/areas/infrastructure/area_repository_factories.dart';
import 'package:forge/features/areas/infrastructure/life_area_command_service_drift.dart';
import 'package:forge/features/areas/infrastructure/life_area_read_repository.dart';

import '../schema/schema_test_database.dart';

/// Command-bus + Drift tests for Life Area management (R-GEN-002, R-GEN-005).
void main() {
  late ForgeSchemaDatabase db;
  late ProfileId profileId;
  late DriftLifeAreaCommandService service;
  late LifeAreaQueryService query;
  int commandSeq = 0;

  CommandId nextId() => CommandId('cmd-${commandSeq++}');

  setUp(() async {
    db = openSchemaDatabase();
    final String id = await insertProfile(db);
    profileId = ProfileId(id);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => id,
      repositoryFactories: areaRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: _FixedClock(),
      afterCommit: AfterCommitDispatcher(),
    );
    service = DriftLifeAreaCommandService(
      bus: bus,
      clock: _FixedClock(),
      idGenerator: _SeqIds(),
    );
    query = LifeAreaReadRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> create(String name, {bool makeDefault = false}) async {
    final Result<CommittedCommandResult> result = await service.create(
      commandId: nextId(),
      profileId: profileId,
      input: CreateLifeAreaInput(name: name, makeDefault: makeDefault),
    );
    expect(result, isA<Success<CommittedCommandResult>>());
    final List<LifeAreaSummary> areas = await query.list(profileId);
    return areas.firstWhere((LifeAreaSummary a) => a.name == name).id.value;
  }

  test('given_new_name_when_created_then_appears_in_list', () async {
    await create('Career');
    final List<LifeAreaSummary> areas = await query.list(profileId);
    expect(areas.map((LifeAreaSummary a) => a.name), <String>['Career']);
  });

  test('given_duplicate_name_when_created_then_rejected', () async {
    await create('Health');
    final Result<CommittedCommandResult> dup = await service.create(
      commandId: nextId(),
      profileId: profileId,
      input: const CreateLifeAreaInput(name: 'health'),
    );
    expect(dup, isA<Failed<CommittedCommandResult>>());
    expect(dup.failureOrNull?.code, 'area.duplicate_name');
  });

  test('given_area_when_renamed_then_name_updates', () async {
    final String id = await create('Persnal');
    final Result<CommittedCommandResult> renamed = await service.rename(
      commandId: nextId(),
      profileId: profileId,
      areaId: LifeAreaId(id),
      input: const RenameLifeAreaInput(name: 'Personal'),
    );
    expect(renamed, isA<Success<CommittedCommandResult>>());
    final List<LifeAreaSummary> areas = await query.list(profileId);
    expect(areas.single.name, 'Personal');
  });

  test(
    'given_three_areas_when_last_reordered_first_then_order_changes',
    () async {
      await create('Career');
      await create('Health');
      final String third = await create('Personal');
      List<LifeAreaSummary> areas = await query.list(profileId);
      expect(areas.map((LifeAreaSummary a) => a.name), <String>[
        'Career',
        'Health',
        'Personal',
      ]);

      // Move "Personal" before the first area (open lower end).
      final Result<CommittedCommandResult> moved = await service.reorder(
        commandId: nextId(),
        profileId: profileId,
        areaId: LifeAreaId(third),
        input: ReorderLifeAreaInput(afterRank: areas.first.rank),
      );
      expect(moved, isA<Success<CommittedCommandResult>>());

      areas = await query.list(profileId);
      expect(areas.map((LifeAreaSummary a) => a.name), <String>[
        'Personal',
        'Career',
        'Health',
      ]);
    },
  );

  test(
    'given_area_when_archived_then_hidden_from_active_but_queryable',
    () async {
      final String id = await create('Finance');
      final Result<CommittedCommandResult> archived = await service.archive(
        commandId: nextId(),
        profileId: profileId,
        areaId: LifeAreaId(id),
      );
      expect(archived, isA<Success<CommittedCommandResult>>());

      final List<LifeAreaSummary> active = await query.list(
        profileId,
        includeArchived: false,
      );
      expect(active, isEmpty);
      final List<LifeAreaSummary> all = await query.list(profileId);
      expect(all.single.isArchived, isTrue);
    },
  );

  test('given_archived_area_when_restored_then_active_again', () async {
    final String id = await create('Finance');
    await service.archive(
      commandId: nextId(),
      profileId: profileId,
      areaId: LifeAreaId(id),
    );
    await service.restore(
      commandId: nextId(),
      profileId: profileId,
      areaId: LifeAreaId(id),
    );
    final List<LifeAreaSummary> active = await query.list(
      profileId,
      includeArchived: false,
    );
    expect(active.single.name, 'Finance');
  });

  test('given_default_area_when_archived_then_rejected', () async {
    final String id = await create('Personal', makeDefault: true);
    final Result<CommittedCommandResult> archived = await service.archive(
      commandId: nextId(),
      profileId: profileId,
      areaId: LifeAreaId(id),
    );
    expect(archived, isA<Failed<CommittedCommandResult>>());
    expect(archived.failureOrNull?.code, 'area.default_cannot_archive');
  });

  test('given_two_areas_when_default_changes_then_only_one_default', () async {
    final String first = await create('Career', makeDefault: true);
    final String second = await create('Health');
    await service.makeDefault(
      commandId: nextId(),
      profileId: profileId,
      areaId: LifeAreaId(second),
    );
    final List<LifeAreaSummary> areas = await query.list(profileId);
    final Iterable<LifeAreaSummary> defaults = areas.where(
      (LifeAreaSummary a) => a.isDefault,
    );
    expect(defaults.length, 1);
    expect(defaults.single.id.value, second);
    expect(
      areas.firstWhere((LifeAreaSummary a) => a.id.value == first).isDefault,
      isFalse,
    );
  });

  test('given_same_command_id_when_replayed_then_idempotent', () async {
    final CommandId id = nextId();
    final Result<CommittedCommandResult> first = await service.create(
      commandId: id,
      profileId: profileId,
      input: const CreateLifeAreaInput(name: 'Learning'),
    );
    final Result<CommittedCommandResult> replay = await service.create(
      commandId: id,
      profileId: profileId,
      input: const CreateLifeAreaInput(name: 'Learning'),
    );
    expect(first, isA<Success<CommittedCommandResult>>());
    expect(replay, isA<Success<CommittedCommandResult>>());
    expect(replay.valueOrNull?.replayed, isTrue);
    final List<LifeAreaSummary> areas = await query.list(profileId);
    expect(areas.length, 1); // no duplicate row from the replay
  });
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime utcNow() => DateTime.utc(2024, 6, 15, 9);
  @override
  String timezoneId() => 'UTC';
}

final class _SeqIds implements IdGenerator {
  int _n = 0;
  @override
  String uuidV7() {
    final String suffix = (_n++).toRadixString(16).padLeft(12, '0');
    return '018f0000-0000-7000-8000-$suffix';
  }
}
