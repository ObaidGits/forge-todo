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
import 'package:forge/features/fitness/presentation/fitness_workout_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the read-only workout detail (`/fitness/:workoutId`)
/// (R-FIT-001, R-FIT-004, R-FIT-005, NFR-A11Y-001/003).
void main() {
  MaterialApp app(String id) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: FitnessWorkoutScreen(workoutId: id)),
  );

  Widget host(_FakeFitnessQuery fake, String id) => ProviderScope(
    overrides: [
      fitnessProfileProvider.overrideWithValue(ProfileId('p1')),
      fitnessQueryServiceProvider.overrideWithValue(fake),
    ],
    child: app(id),
  );

  testWidgets('given_workout_when_opened_then_shows_exercises_and_sets', (
    WidgetTester tester,
  ) async {
    final _FakeFitnessQuery fake = _FakeFitnessQuery(
      session: WorkoutSession(
        id: WorkoutSessionId('w1'),
        lifeAreaId: LifeAreaId('a1'),
        title: 'Leg day',
        startedAtUtc: 0,
        revision: 1,
        createdAtUtc: 0,
        updatedAtUtc: 0,
      ),
      exercises: <ExerciseLog>[
        ExerciseLog(
          id: ExerciseLogId('e1'),
          workoutId: WorkoutSessionId('w1'),
          name: 'Squat',
          rank: 'n',
        ),
      ],
      sets: <SetLog>[
        SetLog(
          id: SetLogId('s1'),
          exerciseLogId: ExerciseLogId('e1'),
          rank: 'n',
          reps: 5,
          weight: MeasuredQuantity.of(100, 'kg'),
        ),
      ],
    );
    await tester.pumpWidget(host(fake, 'w1'));
    await tester.pumpAndSettle();

    expect(find.text('Leg day'), findsOneWidget);
    expect(find.text('Exercises'), findsOneWidget);
    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Set 1'), findsOneWidget);
    // Entered reps and weight/unit are shown verbatim (R-FIT-002).
    expect(find.textContaining('5 reps'), findsOneWidget);
    expect(find.textContaining('100 kg'), findsOneWidget);
  });

  testWidgets('given_unknown_workout_when_opened_then_shows_not_found', (
    WidgetTester tester,
  ) async {
    final _FakeFitnessQuery fake = _FakeFitnessQuery();
    await tester.pumpWidget(host(fake, 'missing'));
    await tester.pumpAndSettle();

    expect(find.text('This workout could not be found.'), findsOneWidget);
  });
}

final class _FakeFitnessQuery implements FitnessQueryService {
  _FakeFitnessQuery({
    this.session,
    this.exercises = const <ExerciseLog>[],
    this.sets = const <SetLog>[],
  });

  final WorkoutSession? session;
  final List<ExerciseLog> exercises;
  final List<SetLog> sets;

  @override
  Future<WorkoutSession?> findWorkoutSession(
    String profileId,
    String sessionId,
  ) async =>
      (session != null && session!.id.value == sessionId) ? session : null;

  @override
  Future<List<ExerciseLog>> sessionExercises(
    String profileId,
    String sessionId,
  ) async => exercises;

  @override
  Future<List<SetLog>> exerciseSets(
    String profileId,
    String exerciseLogId,
  ) async => sets;

  @override
  Future<List<WorkoutTemplate>> workoutTemplates(String profileId) async =>
      const <WorkoutTemplate>[];

  @override
  Future<List<WorkoutSession>> sessionHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async => const <WorkoutSession>[];

  @override
  Future<List<BodyMeasurement>> bodyMeasurementHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async => const <BodyMeasurement>[];

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
