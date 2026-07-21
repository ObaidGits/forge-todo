import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/areas/application/life_area_command_service.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';
import 'package:forge/features/areas/infrastructure/area_repository_factories.dart';
import 'package:forge/features/areas/infrastructure/life_area_command_service_drift.dart';
import 'package:forge/features/areas/infrastructure/life_area_read_repository.dart';
import 'package:forge/features/areas/presentation/area_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';

/// Composes the full areas presentation stack over a real encrypted-schema
/// Drift database and pumps the Life Area management screen through the real
/// Forge router so route wiring is exercised end to end (R-GEN-002).
final class AreasWidgetHarness {
  AreasWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.command,
    required this.query,
  });

  static Future<AreasWidgetHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String id = await insertProfile(db);
    const _FixedClock clock = _FixedClock();
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => id,
      repositoryFactories: areaRepositoryFactories,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );
    return AreasWidgetHarness._(
      db: db,
      profileId: ProfileId(id),
      command: DriftLifeAreaCommandService(
        bus: bus,
        clock: clock,
        idGenerator: _SeqIds(),
      ),
      query: LifeAreaReadRepository(db),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final DriftLifeAreaCommandService command;
  final LifeAreaQueryService query;

  int _seq = 0;
  CommandId nextCommandId() => CommandId('cmd-w-${_seq++}');

  Future<void> close() => db.close();

  LifeAreaCommandService get commandService => command;

  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/settings/areas',
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
          areasProfileProvider.overrideWithValue(profileId),
          lifeAreaQueryServiceProvider.overrideWithValue(query),
          lifeAreaCommandServiceProvider.overrideWithValue(command),
          areasCommandIdFactoryProvider.overrideWithValue(nextCommandId),
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
