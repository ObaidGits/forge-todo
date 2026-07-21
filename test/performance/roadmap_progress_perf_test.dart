import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/roadmap_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/roadmap_read_repository.dart';
import 'package:forge/features/goals/infrastructure/roadmap_repository_factories.dart';

import '../database/schema/schema_test_database.dart';
import '../database/tasks/task_test_support.dart';
import '../helpers/fake_clock.dart';
import '../helpers/fake_id_generator.dart';

/// In-process performance guard for deriving roadmap progress and rendering the
/// roadmap outline over a **large roadmap** (R-GOAL-004, NFR-PERF-003).
///
/// The authoritative NFR-PERF-003 evidence is an external reference-profile
/// campaign that runs a packaged build against the versioned benchmark profile
/// (tool/probes/benchmark_profile + docs/evidence/BENCHMARK-PROFILE.md) on
/// ratified hardware with the external 1×/2× corpora (which hold 10,000 roadmap
/// topics at 1×). That campaign is external evidence and cannot run in a unit
/// harness.
///
/// This guard is the automated regression tripwire that complements it: it
/// builds a real Drift-backed roadmap with hundreds of sections/topics and
/// asserts that the topic-leaf derived-progress computation and the full
/// section+topic outline projection stay well inside a documented tripwire, so
/// a query-plan or unbounded-materialization regression (for example, an N+1
/// per-topic query or a per-topic re-scan) fails fast in CI rather than only
/// surfacing in the periodic reference campaign. It never weakens or
/// substitutes for the reference-profile requirement.
///
/// **Validates: Requirements R-GOAL-004, NFR-PERF-003**
void main() {
  late _RoadmapPerfHarness h;

  setUp(() async {
    h = await _RoadmapPerfHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  // A large-but-CI-friendly roadmap: 30 sections × 20 topics = 600 topic
  // leaves, roughly half completed, some archived/cancelled/ineligible so the
  // eligibility filter is genuinely exercised. This is a regression tripwire,
  // not the authoritative reference scale.
  const int sections = 30;
  const int topicsPerSection = 20;
  const int totalTopics = sections * topicsPerSection;

  test(
    '[TEST-PERF-ROADMAP-PROGRESS-001][MVP][TASK-6.6][R-GOAL-004,NFR-PERF-003] '
    'derived progress and the full outline over a large roadmap stay within '
    'the regression tripwire',
    () async {
      final String goalId = await h.createGoal();
      final String roadmapId = await h.createRoadmap(goalId);
      for (int s = 0; s < sections; s += 1) {
        final String sectionId = await h.addSection(roadmapId, seed: 'sec-$s');
        for (int t = 0; t < topicsPerSection; t += 1) {
          final int n = s * topicsPerSection + t;
          // Vary weights (including a null-weight cohort) and statuses.
          final num? weight = n % 5 == 0 ? null : (n % 4);
          final String topicId = await h.addTopic(
            sectionId,
            seed: 'top-$n',
            weight: weight,
          );
          // Complete ~half; archive/cancel a slice so eligibility is exercised.
          if (n % 2 == 0) {
            await h.setTopicStatus(
              topicId,
              RoadmapTopicStatus.completed,
              seed: 'st-$n',
            );
          } else if (n % 7 == 0) {
            await h.setTopicStatus(
              topicId,
              RoadmapTopicStatus.archived,
              seed: 'st-$n',
            );
          }
        }
      }

      expect(
        await h.scalar('SELECT COUNT(*) FROM roadmap_topics'),
        totalTopics,
      );

      final GoalId goal = GoalId(goalId);
      final Roadmap roadmap = (await h.reads.findByGoal(h.profileId, goal))!;

      // Warm caches and prepared statements.
      for (int i = 0; i < 8; i += 1) {
        await h.reads.deriveGoalProgress(h.profileId, goal);
        await _outline(h, roadmap.id);
      }

      const int samples = 40;
      final List<double> derivedMillis = <double>[];
      final List<double> outlineMillis = <double>[];
      for (int i = 0; i < samples; i += 1) {
        final Stopwatch d = Stopwatch()..start();
        final GoalProgress progress = await h.reads.deriveGoalProgress(
          h.profileId,
          goal,
        );
        d.stop();
        // The derived progress is genuinely computed over the eligible leaves.
        expect(progress.isComputable, isTrue);
        expect(progress.value, inInclusiveRange(0.0, 1.0));
        expect(progress.eligibleCount, greaterThan(0));
        derivedMillis.add(d.elapsedMicroseconds / 1000.0);

        final Stopwatch o = Stopwatch()..start();
        final int rendered = await _outline(h, roadmap.id);
        o.stop();
        expect(rendered, totalTopics);
        outlineMillis.add(o.elapsedMicroseconds / 1000.0);
      }

      final double derivedP95 = _p95(derivedMillis);
      final double outlineP95 = _p95(outlineMillis);

      // Documented regression tripwire. The reference-scale absolute budgets
      // (p95 ≤100 ms for common queries at 1×/2×) are asserted by the external
      // campaign; at this reduced scale in-process both operations have ample
      // headroom, so this generous ceiling only trips on a real algorithmic
      // regression (scan/N+1/unbounded materialization).
      const double tripwireMs = 100.0;
      expect(
        derivedP95,
        lessThan(tripwireMs),
        reason:
            'derived roadmap progress p95 = ${derivedP95.toStringAsFixed(2)} '
            'ms over $totalTopics topics exceeds the ${tripwireMs}ms tripwire',
      );
      expect(
        outlineP95,
        lessThan(tripwireMs),
        reason:
            'roadmap outline p95 = ${outlineP95.toStringAsFixed(2)} ms over '
            '$totalTopics topics exceeds the ${tripwireMs}ms tripwire',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Projects the full outline the way the roadmap screen does: every section in
/// rank order plus every topic under the roadmap in stable order. Returns the
/// total topic count so the caller can assert the projection is materialized
/// (not a lazy handle).
Future<int> _outline(_RoadmapPerfHarness h, RoadmapId roadmapId) async {
  final List<RoadmapSection> sections = await h.reads.sectionsOf(
    h.profileId,
    roadmapId,
  );
  final List<RoadmapTopic> topics = await h.reads.topicsOfRoadmap(
    h.profileId,
    roadmapId,
  );
  // Touch the section list so the query is not dead-code eliminated.
  expect(sections, isNotEmpty);
  return topics.length;
}

double _p95(List<double> samples) {
  final List<double> sorted = List<double>.of(samples)..sort();
  return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
}

/// Minimal Drift-backed goal+roadmap command/read wiring for the benchmark.
final class _RoadmapPerfHarness {
  _RoadmapPerfHarness._(
    this._db,
    this.profileId,
    this._lifeAreaId,
    this._goals,
    this._roadmaps,
    this.reads,
  );

  final ForgeSchemaDatabase _db;
  final ProfileId profileId;
  final LifeAreaId _lifeAreaId;
  final DriftGoalCommandService _goals;
  final DriftRoadmapCommandService _roadmaps;
  final RoadmapReadRepository reads;

  int _cmd = 0;
  CommandId _next(String seed) => CommandId('cmd-$seed-${_cmd++}');

  static Future<_RoadmapPerfHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1));
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...goalRepositoryFactories,
        ...roadmapRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    return _RoadmapPerfHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId('area-1'),
      DriftGoalCommandService(bus: bus, clock: clock, idGenerator: ids),
      DriftRoadmapCommandService(bus: bus, clock: clock, idGenerator: ids),
      RoadmapReadRepository(db),
    );
  }

  Future<void> close() => _db.close();

  Future<int> scalar(String sql) async {
    final List<QueryRow> rows = await _db.customSelect(sql).get();
    return rows.single.data.values.first as int;
  }

  String _idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  Future<String> createGoal() async => _idOf(
    await _goals.create(
      commandId: _next('goal'),
      profileId: profileId,
      input: CreateGoalInput(
        lifeAreaId: _lifeAreaId,
        title: 'Large roadmap',
        progressMode: GoalProgressMode.derived,
      ),
    ),
  );

  Future<String> createRoadmap(String goalId) async => _idOf(
    await _roadmaps.createRoadmap(
      commandId: _next('rm'),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: const CreateRoadmapInput(title: 'Path'),
    ),
  );

  Future<String> addSection(String roadmapId, {required String seed}) async =>
      _idOf(
        await _roadmaps.addSection(
          commandId: _next(seed),
          profileId: profileId,
          roadmapId: RoadmapId(roadmapId),
          input: const CreateSectionInput(title: 'Section'),
        ),
      );

  Future<String> addTopic(
    String sectionId, {
    required String seed,
    num? weight,
  }) async => _idOf(
    await _roadmaps.addTopic(
      commandId: _next(seed),
      profileId: profileId,
      sectionId: RoadmapSectionId(sectionId),
      input: CreateTopicInput(title: 'Topic', weight: weight),
    ),
  );

  Future<void> setTopicStatus(
    String topicId,
    RoadmapTopicStatus status, {
    required String seed,
  }) async {
    await _roadmaps.setTopicStatus(
      commandId: _next(seed),
      profileId: profileId,
      topicId: RoadmapTopicId(topicId),
      status: status,
    );
  }
}
