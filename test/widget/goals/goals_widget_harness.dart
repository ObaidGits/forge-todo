import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_read_repository.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/roadmap_read_repository.dart';
import 'package:forge/features/goals/infrastructure/roadmap_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';
import '../../database/tasks/task_test_support.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

/// Composes the full goals + roadmap presentation stack over a real
/// encrypted-schema Drift database: goal and roadmap command services sharing
/// one transactional command bus with the in-transaction search coordinator,
/// plus the exported read repositories. Screens are pumped through the real
/// Forge router so route wiring is exercised end to end.
final class GoalsWidgetHarness {
  GoalsWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.goals,
    required this.roadmaps,
    required this.goalReads,
    required this.roadmapReads,
  });

  static Future<GoalsWidgetHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry =
        SearchProjectionRegistry(const <SearchProjector>[
          TaskSearchProjector(),
          NoteSearchProjector(),
          GoalSearchProjector(),
          RoadmapTopicSearchProjector(),
        ]);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...goalRepositoryFactories,
        ...roadmapRepositoryFactories,
        ...noteRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    return GoalsWidgetHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      goals: DriftGoalCommandService(bus: bus, clock: clock, idGenerator: ids),
      roadmaps: DriftRoadmapCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      goalReads: GoalReadRepository(db),
      roadmapReads: RoadmapReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final DriftGoalCommandService goals;
  final DriftRoadmapCommandService roadmaps;
  final GoalReadRepository goalReads;
  final RoadmapReadRepository roadmapReads;

  int _commandSeq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_commandSeq++}');

  Future<void> close() => db.close();

  String _idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  /// Creates a goal and returns its id.
  Future<String> createGoal({
    String title = 'Learn Rust',
    String outcomeMd = '',
    GoalProgressMode progressMode = GoalProgressMode.derived,
    double? manualProgress,
    String? targetDate,
  }) async {
    final Result<CommittedCommandResult> result = await goals.create(
      commandId: nextCommandId(),
      profileId: profileId,
      input: CreateGoalInput(
        lifeAreaId: lifeAreaId,
        title: title,
        outcomeMd: outcomeMd,
        targetDate: targetDate,
        progressMode: progressMode,
        manualProgress: progressMode == GoalProgressMode.manual
            ? (manualProgress ?? 0)
            : null,
      ),
    );
    return _idOf(result);
  }

  Future<String> addMilestone(
    String goalId, {
    String title = 'Milestone',
  }) async {
    final Result<CommittedCommandResult> result = await goals.addMilestone(
      commandId: nextCommandId(),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: CreateMilestoneInput(title: title),
    );
    return _idOf(result);
  }

  Future<String> createRoadmap(String goalId, {String title = 'Path'}) async {
    final Result<CommittedCommandResult> result = await roadmaps.createRoadmap(
      commandId: nextCommandId(),
      profileId: profileId,
      goalId: GoalId(goalId),
      input: CreateRoadmapInput(title: title),
    );
    return _idOf(result);
  }

  Future<String> addSection(
    String roadmapId, {
    String title = 'Section',
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.addSection(
      commandId: nextCommandId(),
      profileId: profileId,
      roadmapId: RoadmapId(roadmapId),
      input: CreateSectionInput(title: title),
    );
    return _idOf(result);
  }

  Future<String> addTopic(
    String sectionId, {
    String title = 'Topic',
    num? weight,
    RoadmapTopicStatus status = RoadmapTopicStatus.open,
  }) async {
    final Result<CommittedCommandResult> result = await roadmaps.addTopic(
      commandId: nextCommandId(),
      profileId: profileId,
      sectionId: RoadmapSectionId(sectionId),
      input: CreateTopicInput(title: title, weight: weight, status: status),
    );
    return _idOf(result);
  }

  /// Pumps the real Forge router (shell + routes) at [initialLocation] with the
  /// goals stack wired to this harness.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/goals',
    Size size = const Size(1100, 1800),
    double textScale = 1,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createForgeRouter(initialLocation: initialLocation);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goalsProfileProvider.overrideWithValue(profileId),
          goalsRepositoryProvider.overrideWithValue(goalReads),
          roadmapRepositoryProvider.overrideWithValue(roadmapReads),
          goalsCommandServiceProvider.overrideWithValue(goals),
          roadmapCommandServiceProvider.overrideWithValue(roadmaps),
          goalsCommandIdFactoryProvider.overrideWithValue(nextCommandId),
          goalsAreaOptionsProvider.overrideWithValue(<GoalAreaOption>[
            GoalAreaOption(id: lifeAreaId, name: 'Career'),
          ]),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) {
            final MediaQueryData data = MediaQuery.of(context);
            return MediaQuery(
              data: data.copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: disableAnimations,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
