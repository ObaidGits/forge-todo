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
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/learning/presentation/learning_providers.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';
import '../../database/tasks/task_test_support.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

/// Composes the full learning presentation stack over a real encrypted-schema
/// Drift database: the durable command service sharing one transactional
/// command bus with the in-transaction search coordinator, plus the exported
/// read repository. Screens are pumped through the real Forge router so the
/// /learn route wiring is exercised end to end.
final class LearningWidgetHarness {
  LearningWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.commands,
    required this.reads,
  });

  static Future<LearningWidgetHarness> open({
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
    return LearningWidgetHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      commands: DriftLearningCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      reads: LearningReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final DriftLearningCommandService commands;
  final LearningReadRepository reads;

  int _commandSeq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_commandSeq++}');

  Future<void> close() => db.close();

  String _idOf(Result<CommittedCommandResult> result, String key) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)[key]
        as String;
  }

  /// Creates a Learning Resource and returns its id.
  Future<String> createResource({
    String title = 'Flutter in Depth',
    LearningResourceType type = LearningResourceType.course,
  }) async {
    final Result<CommittedCommandResult> result = await commands.createResource(
      commandId: nextCommandId(),
      profileId: profileId,
      input: CreateResourceInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        type: type,
      ),
    );
    return _idOf(result, 'resource_id');
  }

  /// Appends an eligible item and returns its id.
  Future<String> addItem(
    String resourceId, {
    String title = 'Lesson 1',
    LearningItemType type = LearningItemType.lesson,
  }) async {
    final Result<CommittedCommandResult> result = await commands.addItem(
      commandId: nextCommandId(),
      profileId: profileId,
      input: AddItemInput(resourceId: resourceId, title: title, type: type),
    );
    return _idOf(result, 'item_id');
  }

  /// Pumps the real Forge router (shell + routes) at [initialLocation] with the
  /// learning stack wired to this harness.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/learn',
    Size size = const Size(1100, 1800),
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
          learningProfileProvider.overrideWithValue(profileId),
          learningRepositoryProvider.overrideWithValue(reads),
          learningCommandServiceProvider.overrideWithValue(commands),
          learningClockProvider.overrideWithValue(clock),
          learningDefaultAreaProvider.overrideWithValue(lifeAreaId),
          learningCommandIdFactoryProvider.overrideWithValue(nextCommandId),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
