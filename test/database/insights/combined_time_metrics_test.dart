import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/infrastructure/focus_command_service_drift.dart';
import 'package:forge/features/focus/infrastructure/focus_read_repository.dart';
import 'package:forge/features/focus/infrastructure/focus_repository_factories.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

int _us(DateTime t) => t.microsecondsSinceEpoch;

/// One Drift store wired with both focus and learning so the insights combined
/// metric can union real focus work spans with real study spans.
final class _CombinedHarness {
  _CombinedHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.monotonic,
    this.ids,
    this.focus,
    this.learning,
    this.combined,
  );

  static Future<_CombinedHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 9));
    final FakeMonotonicClock monotonic = FakeMonotonicClock(bootId: 'boot-1');
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <SearchProjector>[LearningSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...focusRepositoryFactories,
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
    final FocusReadRepository focusReads = FocusReadRepository(db);
    final LearningReadRepository learningReads = LearningReadRepository(db);
    return _CombinedHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId('area-1'),
      clock,
      monotonic,
      ids,
      DriftFocusCommandService(
        bus: bus,
        clock: clock,
        monotonic: monotonic,
        idGenerator: ids,
      ),
      DriftLearningCommandService(bus: bus, clock: clock, idGenerator: ids),
      CombinedTimeMetricsService(
        focusDuration: focusReads,
        studyDuration: learningReads,
      ),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeMonotonicClock monotonic;
  final FakeIdGenerator ids;
  final DriftFocusCommandService focus;
  final DriftLearningCommandService learning;
  final CombinedTimeMetricsService combined;

  int _cmd = 0;
  CommandId _next(String seed) => CommandId('cmd-$seed-${_cmd++}');

  Future<void> close() => db.close();

  CommittedCommandResult _ok(
    Result<CommittedCommandResult> result,
  ) => switch (result) {
    Success<CommittedCommandResult>(value: final CommittedCommandResult v) => v,
    Failed<CommittedCommandResult>(failure: final Failure f) =>
      throw StateError('Expected success but got ${f.code}'),
  };

  Future<String> createResource() async {
    final CommittedCommandResult r = _ok(
      await learning.createResource(
        commandId: _next('res'),
        profileId: profileId,
        input: CreateResourceInput(
          lifeAreaId: lifeAreaId.value,
          title: 'Algorithms',
          type: LearningResourceType.course,
        ),
      ),
    );
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['resource_id']
        as String;
  }

  Future<void> logStudy(
    String resourceId, {
    required DateTime start,
    required DateTime end,
  }) async {
    _ok(
      await learning.logStudySession(
        commandId: _next('study'),
        profileId: profileId,
        input: LogStudySessionInput(
          resourceId: resourceId,
          startedAtUtc: _us(start),
          endedAtUtc: _us(end),
        ),
      ),
    );
  }

  /// Runs a focus work interval `[start, end)` by anchoring the wall/monotonic
  /// clocks at [start] and advancing them to [end] before ending the session.
  Future<void> focusWork({
    required DateTime start,
    required DateTime end,
  }) async {
    clock.setUtc(start);
    final CommittedCommandResult r = _ok(
      await focus.start(
        commandId: _next('focus'),
        profileId: profileId,
        input: StartFocusSessionInput(
          lifeAreaId: lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      ),
    );
    final String sessionId =
        (jsonDecode(r.resultPayload!) as Map<String, Object?>)['session_id']
            as String;
    final Duration length = end.difference(start);
    clock.advance(length);
    monotonic.advance(length);
    _ok(
      await focus.end(
        commandId: _next('end'),
        profileId: profileId,
        input: EndFocusSessionInput(sessionId: sessionId),
      ),
    );
  }
}

void main() {
  late _CombinedHarness harness;

  setUp(() async {
    harness = await _CombinedHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  group(
    '[TEST-DB-INSIGHT-COMBINED][V1][TASK-7.4][R-INSIGHT-001] combined focus + '
    'study time from real records',
    () {
      test(
        'overlapping focus and study time is counted once, not summed',
        () async {
          final String rid = await harness.createResource();
          // Study 09:00-10:00.
          await harness.logStudy(
            rid,
            start: DateTime.utc(2024, 6, 1, 9),
            end: DateTime.utc(2024, 6, 1, 10),
          );
          // Focus 09:30-10:30 (overlaps the study by 30 minutes).
          await harness.focusWork(
            start: DateTime.utc(2024, 6, 1, 9, 30),
            end: DateTime.utc(2024, 6, 1, 10, 30),
          );

          final CombinedTimeMetrics m = await harness.combined.combinedTime(
            harness.profileId,
            rangeStartUtc: _us(DateTime.utc(2024, 6, 1, 8)),
            rangeEndUtc: _us(DateTime.utc(2024, 6, 1, 12)),
          );

          expect(m.focusSeconds, 3600);
          expect(m.studySeconds, 3600);
          // Union 09:00-10:30 = 5400s, not the naive 7200s.
          expect(m.combinedSeconds, 5400);
          expect(m.overlapSeconds, 1800);
          // The naive sum would double-count the shared half hour.
          expect(
            m.focusSeconds + m.studySeconds,
            greaterThan(m.combinedSeconds),
          );
        },
      );

      test('disjoint focus and study time sums with no overlap', () async {
        final String rid = await harness.createResource();
        await harness.logStudy(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 9, 30),
        );
        await harness.focusWork(
          start: DateTime.utc(2024, 6, 1, 11),
          end: DateTime.utc(2024, 6, 1, 11, 45),
        );

        final CombinedTimeMetrics m = await harness.combined.combinedTime(
          harness.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1, 8)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 1, 12)),
        );

        expect(m.studySeconds, 1800);
        expect(m.focusSeconds, 2700);
        expect(m.combinedSeconds, 4500);
        expect(m.overlapSeconds, 0);
      });

      test('a Life Area filter scopes the combined total', () async {
        final String rid = await harness.createResource();
        await harness.logStudy(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
        );
        await harness.focusWork(
          start: DateTime.utc(2024, 6, 1, 9, 30),
          end: DateTime.utc(2024, 6, 1, 10, 30),
        );

        final CombinedTimeMetrics other = await harness.combined.combinedTime(
          harness.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1, 8)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 1, 12)),
          lifeAreaId: LifeAreaId('area-2'),
        );
        expect(other.combinedSeconds, 0);
        expect(other.lifeAreaId, 'area-2');
      });
    },
  );
}
