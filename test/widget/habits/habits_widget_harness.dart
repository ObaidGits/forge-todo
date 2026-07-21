import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';
import 'package:forge/features/habits/infrastructure/habit_command_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_query_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_repository_factories.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';
import '../../database/tasks/task_test_support.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';

/// Composes the full habits presentation stack over a real encrypted-schema
/// Drift database: the habit command service and the read-side query service
/// sharing one transactional command bus. Screens are pumped through the real
/// Forge router so route wiring is exercised end to end.
final class HabitsWidgetHarness {
  HabitsWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.lifeAreaId,
    required this.clock,
    required this.service,
    required this.query,
  });

  static Future<HabitsWidgetHarness> open({DateTime? initialUtc}) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: habitRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    return HabitsWidgetHarness._(
      db: db,
      profileId: ProfileId(profileId),
      lifeAreaId: LifeAreaId('area-1'),
      clock: clock,
      service: DriftHabitCommandService(
        bus: bus,
        clock: clock,
        idGenerator: ids,
      ),
      query: DriftHabitQueryService(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final DriftHabitCommandService service;
  final DriftHabitQueryService query;

  int _commandSeq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_commandSeq++}');

  Future<void> close() => db.close();

  HabitScheduleRule _dailyRule(String startIso) => HabitScheduleRule(
    frequency: HabitFrequency.daily,
    scheduleKind: HabitScheduleKind.dated,
    start: LocalDate.parse(startIso),
    timezoneId: 'Etc/UTC',
  );

  /// Creates a daily boolean habit anchored at [startIso].
  Future<String> createBooleanHabit({
    required String id,
    String title = 'Meditate',
    String startIso = '2024-06-15',
  }) async {
    await service.createHabit(
      commandId: nextCommandId(),
      profileId: profileId,
      habitId: HabitId(id),
      input: CreateHabitInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        rule: _dailyRule(startIso),
        target: HabitTarget.boolean(),
        rank: 'm',
      ),
    );
    return id;
  }

  /// Creates a daily count habit anchored at [startIso].
  Future<String> createCountHabit({
    required String id,
    String title = 'Pushups',
    int target = 3,
    String startIso = '2024-06-15',
  }) async {
    await service.createHabit(
      commandId: nextCommandId(),
      profileId: profileId,
      habitId: HabitId(id),
      input: CreateHabitInput(
        lifeAreaId: lifeAreaId.value,
        title: title,
        rule: _dailyRule(startIso),
        target: HabitTarget.count(target),
        rank: 'm',
      ),
    );
    return id;
  }

  Future<void> checkInBoolean(String habitId, String dateIso) async {
    await service.checkIn(
      commandId: nextCommandId(),
      profileId: profileId,
      habitId: HabitId(habitId),
      input: CheckInInput(
        onDate: LocalDate.parse(dateIso),
        kind: ObservationInputKind.booleanTrue,
      ),
    );
  }

  Future<void> skip(String habitId, String dateIso) async {
    await service.skipOccurrence(
      commandId: nextCommandId(),
      profileId: profileId,
      habitId: HabitId(habitId),
      input: SkipOccurrenceInput(onDate: LocalDate.parse(dateIso)),
    );
  }

  /// Pumps the real Forge router with the habits stack wired to this harness.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/habits',
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
          habitsProfileProvider.overrideWithValue(profileId),
          habitsQueryServiceProvider.overrideWithValue(query),
          habitsCommandServiceProvider.overrideWithValue(service),
          habitsClockProvider.overrideWithValue(clock),
          habitsCommandIdFactoryProvider.overrideWithValue(nextCommandId),
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
