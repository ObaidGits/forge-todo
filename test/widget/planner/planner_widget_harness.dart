import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_command_service_drift.dart';
import 'package:forge/features/planner/infrastructure/planner_read_repository.dart';
import 'package:forge/features/planner/infrastructure/planner_repository_factories.dart';
import 'package:forge/features/planner/presentation/planner_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';
import '../../database/tasks/task_test_support.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

/// Composes the full planner presentation stack over a real encrypted-schema
/// Drift database: the durable command service sharing one transactional
/// command bus, plus the exported read repository. Screens are pumped through
/// the real Forge router so the /planner route wiring is exercised end to end.
final class PlannerWidgetHarness {
  PlannerWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.commands,
    required this.reads,
  });

  static Future<PlannerWidgetHarness> open({
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
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: plannerRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    return PlannerWidgetHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId(areaId),
      clock: clock,
      commands: DriftPlannerCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      reads: PlannerReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final DriftPlannerCommandService commands;
  final PlannerReadRepository reads;

  int _commandSeq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_commandSeq++}');

  Future<void> close() => db.close();

  /// Seeds a daily planning record for [periodKey] so the editor opens with
  /// existing section content.
  Future<void> seedDaily({
    required String periodKey,
    String? morningPlanMd,
    String? dailyPlanMd,
    String? eveningReflectionMd,
  }) async {
    await commands.savePlanningRecord(
      commandId: nextCommandId(),
      profileId: profileId,
      input: SavePlanningRecordInput(
        lifeAreaId: lifeAreaId.value,
        kind: PlanningPeriodKind.day,
        periodKey: periodKey,
        morningPlanMd: morningPlanMd == null
            ? SectionEdit.unchanged
            : SectionEdit.set(morningPlanMd),
        dailyPlanMd: dailyPlanMd == null
            ? SectionEdit.unchanged
            : SectionEdit.set(dailyPlanMd),
        eveningReflectionMd: eveningReflectionMd == null
            ? SectionEdit.unchanged
            : SectionEdit.set(eveningReflectionMd),
      ),
    );
  }

  /// Pumps the real Forge router (shell + routes) at [initialLocation] with the
  /// planner stack wired to this harness.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/planner',
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
          plannerProfileProvider.overrideWithValue(profileId),
          plannerRepositoryProvider.overrideWithValue(reads),
          plannerCommandServiceProvider.overrideWithValue(commands),
          plannerClockProvider.overrideWithValue(clock),
          plannerDefaultAreaProvider.overrideWithValue(lifeAreaId),
          plannerCommandIdFactoryProvider.overrideWithValue(nextCommandId),
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
