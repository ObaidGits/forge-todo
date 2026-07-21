import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/application/water_tracking_settings.dart';
import 'package:forge/features/fitness/domain/fitness_presentation.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/infrastructure/fitness_command_service_drift.dart';
import 'package:forge/features/fitness/infrastructure/fitness_read_repository.dart';
import 'package:forge/features/fitness/infrastructure/fitness_repository_factories.dart';
import 'package:forge/features/fitness/infrastructure/settings_water_tracking_store.dart';
import 'package:forge/features/fitness/infrastructure/workout_search_projector.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/infrastructure/search_index_maintenance.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Wiring for real Drift-backed workout↔search integration tests: the fitness
/// command service with the in-transaction search coordinator (the workout
/// projector), the unified search read model, index maintenance, and the
/// fitness read model that exposes underlying records.
final class _WorkoutSearchHarness {
  _WorkoutSearchHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.service,
    this.search,
    this.reads,
    this.maintenance,
  );

  static Future<_WorkoutSearchHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12));
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <WorkoutSearchProjector>[WorkoutSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...fitnessRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    final WaterTrackingSettings water = SettingsWaterTrackingStore(db, clock);
    final DriftFitnessCommandService service = DriftFitnessCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
      waterTracking: water,
    );
    return _WorkoutSearchHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId('area-1'),
      service,
      SearchReadRepository(db),
      FitnessReadRepository(db),
      SearchIndexMaintenance(
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
  final DriftFitnessCommandService service;
  final SearchReadRepository search;
  final FitnessReadRepository reads;
  final SearchIndexMaintenance maintenance;

  int _cmd = 0;

  Future<void> close() => db.close();

  /// Logs a "Morning push" workout with one benchpress set at [weightValue]
  /// [weightUnit], returning the session id.
  Future<String> logMorningPush({
    String title = 'Morning push',
    num weightValue = 135,
    String weightUnit = 'lb',
  }) async {
    final String sessionId = 'workout-${_cmd++}';
    await service.logWorkoutSession(
      commandId: CommandId('cmd-${_cmd++}'),
      profileId: profileId,
      sessionId: WorkoutSessionId(sessionId),
      input: LogWorkoutSessionInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        startedAtUtc: DateTime.utc(2024, 6, 1, 7).microsecondsSinceEpoch,
        exercises: <ExerciseLogInput>[
          ExerciseLogInput(
            name: 'Bench press',
            rank: 'a',
            sets: <SetLogInput>[
              SetLogInput(
                rank: 'a',
                reps: 5,
                weightValue: weightValue,
                weightUnit: weightUnit,
              ),
            ],
          ),
        ],
      ),
    );
    return sessionId;
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
}

/// Real Drift-backed integration of V1 fitness workouts into the unified search
/// index, entity vocabulary, and non-medical presentation policy.
///
/// **Validates: Requirements R-SEARCH-001, R-FIT-001, R-FIT-002, R-FIT-004,
/// R-FIT-005**
///
/// Evidence: [TEST-FIT-SEARCH-001][V1][TASK-10.5]
void main() {
  late _WorkoutSearchHarness h;

  setUp(() async {
    h = await _WorkoutSearchHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('indexing (R-SEARCH-001)', () {
    test('logging a workout makes it FTS-findable by title', () async {
      final String id = await h.logMorningPush();

      final SearchResults results = await h.search.search(
        h.profileId,
        'Morning',
      );
      expect(results.totalHits, 1);
      final SearchResultGroup group = results.groups.single;
      expect(group.entityType, WorkoutSearchProjector.kind);
      expect(group.hits.single.entityId, id);
      expect(group.hits.single.title, 'Morning push');
    });

    test(
      'the search_documents row is written atomically with the workout',
      () async {
        final String id = await h.logMorningPush();
        expect(
          await h.scalarInt(
            "SELECT COUNT(*) FROM search_documents WHERE entity_type = 'workout' "
            'AND entity_id = ? AND deleted = 0',
            <Object?>[id],
          ),
          1,
        );
      },
    );

    test('a type-filtered search returns only the workout group', () async {
      await h.logMorningPush();
      final SearchResults results = await h.search.search(
        h.profileId,
        'Morning',
        types: <String>{WorkoutSearchProjector.kind},
      );
      expect(results.groups.single.entityType, WorkoutSearchProjector.kind);
    });
  });

  group('opening the canonical record (R-SEARCH-002)', () {
    test('the workout type resolves to its /fitness/<id> route', () async {
      final String id = await h.logMorningPush();
      // The projector discriminator matches the canonical vocabulary.
      expect(WorkoutSearchProjector.kind, CanonicalEntityType.workout);
      expect(CanonicalRoute.isAddressable(WorkoutSearchProjector.kind), isTrue);
      expect(CanonicalRoute.forEntity('workout', id), '/fitness/$id');
    });
  });

  group('lifecycle (R-SEARCH-001)', () {
    test('a soft-deleted workout is dropped on a source rebuild', () async {
      final String id = await h.logMorningPush();
      expect((await h.search.search(h.profileId, 'Morning')).totalHits, 1);

      // Simulate deletion of the underlying record, then rebuild from sources.
      await h.db.customStatement(
        'UPDATE workout_sessions SET deleted_at_utc = ? WHERE id = ?',
        <Object?>[DateTime.utc(2024, 6, 2).microsecondsSinceEpoch, id],
      );
      final int regenerated = await h.maintenance.rebuildFromSources(
        h.profileId.value,
      );
      expect(regenerated, 0);
      expect((await h.search.search(h.profileId, 'Morning')).totalHits, 0);
    });

    test('a rebuild regenerates the workout document from source', () async {
      await h.logMorningPush();
      // Corrupt the index content to prove the rebuild restores it from source.
      await h.db.customStatement('DELETE FROM search_documents');
      final int regenerated = await h.maintenance.rebuildFromSources(
        h.profileId.value,
      );
      expect(regenerated, 1);
      expect((await h.search.search(h.profileId, 'Morning')).totalHits, 1);
    });
  });

  group('unit preservation and underlying records (R-FIT-002, R-FIT-004)', () {
    test('indexing never rewrites the entered set weight/unit', () async {
      final String id = await h.logMorningPush(
        weightValue: 60,
        weightUnit: 'kg',
      );

      // The workout is indexed…
      expect((await h.search.search(h.profileId, 'Morning')).totalHits, 1);

      // …and the underlying set record still exposes the exact entered value
      // and unit behind it (R-FIT-002, R-FIT-004).
      final List<ExerciseLog> exercises = await h.reads.exerciseLogs(
        h.profileId.value,
        id,
      );
      expect(exercises, hasLength(1));
      final List<SetLog> sets = await h.reads.setLogs(
        h.profileId.value,
        exercises.single.id.value,
      );
      expect(sets, hasLength(1));
      expect(sets.single.weight!.enteredValue, 60);
      expect(sets.single.weight!.enteredUnit, 'kg');
      expect(FitnessPresentation.exposesUnderlyingRecords, isTrue);
    });
  });

  group('non-medical presentation (R-FIT-004, R-FIT-005)', () {
    test('the indexed document carries no medical interpretation', () async {
      await h.logMorningPush();
      final Map<String, Object?>? row = await h.firstRow(
        "SELECT title, body FROM search_documents WHERE entity_type = 'workout'",
      );
      expect(row, isNotNull);
      final String title = (row!['title'] as String).toLowerCase();
      final String body = ((row['body'] as String?) ?? '').toLowerCase();
      // The projector indexes only the neutral, user-entered title; it never
      // derives a health claim (R-FIT-004, R-FIT-005).
      expect(title, 'morning push');
      expect(body, isEmpty);
      for (final String term
          in FitnessPresentation.prohibitedInterpretationTerms) {
        expect(title.contains(term), isFalse, reason: 'title has "$term"');
        expect(body.contains(term), isFalse, reason: 'body has "$term"');
      }
      expect(FitnessPresentation.appliesMedicalInterpretation, isFalse);
    });
  });
}
