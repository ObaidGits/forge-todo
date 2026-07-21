import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/application/fitness_query_service.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/presentation/fitness_providers.dart';
import 'package:forge/features/fitness/presentation/fitness_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the Fitness screen (R-FIT-001, R-FIT-002, R-FIT-004,
/// R-FIT-005, NFR-A11Y-001/003).
///
/// The screen renders real workout templates, logged workouts, and body-weight
/// measurements instead of the placeholder, preserving the exact entered
/// value/unit and adding no medical interpretation. When the read stack is not
/// wired it shows a calm not-available empty state.
void main() {
  const Widget app = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: FitnessScreen()),
  );

  testWidgets('given_not_wired_when_opened_then_shows_not_available_state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: app));
    await tester.pumpAndSettle();

    expect(find.text("Fitness isn't available yet."), findsOneWidget);
  });

  testWidgets(
    'given_records_when_opened_then_lists_templates_sessions_and_weight',
    (WidgetTester tester) async {
      final _FakeFitnessQuery query = _FakeFitnessQuery(
        templates: <WorkoutTemplate>[_template('Push day')],
        sessions: <WorkoutSession>[_session('Morning run')],
        measurements: <BodyMeasurement>[_measurement(80.5, 'kg')],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fitnessProfileProvider.overrideWithValue(ProfileId('profile-1')),
            fitnessQueryServiceProvider.overrideWithValue(query),
            fitnessDefaultAreaProvider.overrideWithValue(LifeAreaId('area-1')),
          ],
          child: app,
        ),
      );
      await tester.pumpAndSettle();

      // Section headers are present.
      expect(find.text('Workout templates'), findsOneWidget);
      expect(find.text('Recent workouts'), findsOneWidget);
      expect(find.text('Body weight'), findsOneWidget);

      // Real records render, and the entered value/unit is shown verbatim.
      expect(find.text('Push day'), findsOneWidget);
      expect(find.text('Morning run'), findsOneWidget);
      expect(find.text('80.5 kg'), findsOneWidget);
    },
  );

  testWidgets('given_no_records_when_wired_then_sections_show_empty_messages', (
    WidgetTester tester,
  ) async {
    final _FakeFitnessQuery query = _FakeFitnessQuery();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fitnessProfileProvider.overrideWithValue(ProfileId('profile-1')),
          fitnessQueryServiceProvider.overrideWithValue(query),
          fitnessDefaultAreaProvider.overrideWithValue(LifeAreaId('area-1')),
        ],
        child: app,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No workout templates yet. Create one to get started.'),
      findsOneWidget,
    );
    expect(find.text('No workouts logged yet.'), findsOneWidget);
    expect(find.text('No body-weight measurements yet.'), findsOneWidget);
  });
}

WorkoutTemplate _template(String title) => WorkoutTemplate(
  id: WorkoutTemplateId('tpl-1'),
  lifeAreaId: LifeAreaId('area-1'),
  title: title,
  rank: 'n',
  status: WorkoutTemplateStatus.active,
  revision: 1,
  createdAtUtc: 0,
  updatedAtUtc: 0,
);

WorkoutSession _session(String title) => WorkoutSession(
  id: WorkoutSessionId('sess-1'),
  lifeAreaId: LifeAreaId('area-1'),
  title: title,
  startedAtUtc: 1000,
  revision: 1,
  createdAtUtc: 0,
  updatedAtUtc: 0,
);

BodyMeasurement _measurement(num value, String unit) => BodyMeasurement(
  id: BodyMeasurementId('bm-1'),
  lifeAreaId: LifeAreaId('area-1'),
  kind: BodyMeasurementKind.weight,
  value: MeasuredQuantity.of(value, unit),
  measuredAtUtc: 1000,
  revision: 1,
  createdAtUtc: 0,
  updatedAtUtc: 0,
);

/// A minimal in-memory [FitnessQueryService] for widget tests.
final class _FakeFitnessQuery implements FitnessQueryService {
  _FakeFitnessQuery({
    this.templates = const <WorkoutTemplate>[],
    this.sessions = const <WorkoutSession>[],
    this.measurements = const <BodyMeasurement>[],
  });

  final List<WorkoutTemplate> templates;
  final List<WorkoutSession> sessions;
  final List<BodyMeasurement> measurements;

  @override
  Future<List<WorkoutTemplate>> workoutTemplates(String profileId) async =>
      templates;

  @override
  Future<WorkoutSession?> findWorkoutSession(
    String profileId,
    String sessionId,
  ) async {
    for (final WorkoutSession session in sessions) {
      if (session.id.value == sessionId) {
        return session;
      }
    }
    return null;
  }

  @override
  Future<List<WorkoutSession>> sessionHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async => sessions;

  @override
  Future<List<BodyMeasurement>> bodyMeasurementHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async => measurements;

  @override
  Future<List<ExerciseLog>> sessionExercises(
    String profileId,
    String sessionId,
  ) async => const <ExerciseLog>[];

  @override
  Future<List<SetLog>> exerciseSets(
    String profileId,
    String exerciseLogId,
  ) async => const <SetLog>[];

  @override
  Future<List<BodyWeightPoint>> bodyWeightSeries(
    String profileId, {
    required int fromUtc,
    required int toUtc,
    required String displayUnit,
  }) async => const <BodyWeightPoint>[];

  @override
  Future<bool> isWaterTrackingEnabled(String profileId) async => false;

  @override
  Future<List<WaterEvent>> waterEventHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async => const <WaterEvent>[];
}
