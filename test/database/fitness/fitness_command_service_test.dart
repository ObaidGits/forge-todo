import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/application/fitness_query_service.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';

import 'fitness_test_support.dart';

/// Real Drift-backed fitness command flows and history (R-FIT-001, R-FIT-002,
/// R-FIT-004).
void main() {
  late FitnessHarness harness;

  setUp(() async {
    harness = await FitnessHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  group('createWorkoutTemplate (R-FIT-001)', () {
    test('persists a template and its ordered exercises', () async {
      final Result<Object> result = await harness.service.createWorkoutTemplate(
        commandId: harness.nextCommandId('tmpl'),
        profileId: harness.profileId,
        templateId: WorkoutTemplateId('tmpl-1'),
        input: const CreateWorkoutTemplateInput(
          lifeAreaId: 'area-1',
          title: 'Push Day',
          rank: 'm',
          exercises: <TemplateExerciseInput>[
            TemplateExerciseInput(
              name: 'Bench Press',
              rank: 'a',
              targetSets: 5,
              targetReps: 5,
            ),
            TemplateExerciseInput(name: 'Overhead Press', rank: 'b'),
          ],
        ),
      );

      expect(result, isA<Success<Object>>());
      expect(await harness.scalar('SELECT COUNT(*) FROM workout_templates'), 1);
      expect(
        await harness.scalar('SELECT COUNT(*) FROM template_exercises'),
        2,
      );

      final List<WorkoutTemplate> templates = await harness.queries
          .workoutTemplates(harness.profileId.value);
      expect(templates.single.title, 'Push Day');
    });
  });

  group('logWorkoutSession (R-FIT-001, R-FIT-002)', () {
    test('persists session, exercises, and sets with preserved units', () async {
      final Result<Object> result = await harness.service.logWorkoutSession(
        commandId: harness.nextCommandId('sess'),
        profileId: harness.profileId,
        sessionId: WorkoutSessionId('sess-1'),
        input: LogWorkoutSessionInput(
          lifeAreaId: 'area-1',
          title: 'Morning Lift',
          startedAtUtc: 1000,
          endedAtUtc: 4600,
          durationSec: 3600,
          exercises: const <ExerciseLogInput>[
            ExerciseLogInput(
              name: 'Bench Press',
              rank: 'a',
              sets: <SetLogInput>[
                SetLogInput(
                  rank: 'a',
                  reps: 5,
                  weightValue: 135,
                  weightUnit: 'lb',
                ),
                SetLogInput(
                  rank: 'b',
                  reps: 5,
                  weightValue: 60,
                  weightUnit: 'kg',
                ),
              ],
            ),
            ExerciseLogInput(
              name: 'Treadmill',
              rank: 'b',
              sets: <SetLogInput>[
                SetLogInput(
                  rank: 'a',
                  durationSec: 600,
                  distanceValue: 2.5,
                  distanceUnit: 'km',
                ),
              ],
            ),
          ],
        ),
      );

      expect(result, isA<Success<Object>>());
      expect(await harness.scalar('SELECT COUNT(*) FROM workout_sessions'), 1);
      expect(await harness.scalar('SELECT COUNT(*) FROM exercise_logs'), 2);
      expect(await harness.scalar('SELECT COUNT(*) FROM set_logs'), 3);

      // The entered lb value and unit are preserved verbatim, while a canonical
      // milligram amount is derived for computation (R-FIT-002).
      final Map<String, Object?>? lbSet = await harness.firstRow(
        "SELECT weight_entered, weight_unit, weight_scaled FROM set_logs "
        "WHERE weight_unit = 'lb'",
      );
      expect(lbSet!['weight_entered'], 135.0);
      expect(lbSet['weight_unit'], 'lb');
      expect(lbSet['weight_scaled'], 135 * 453592);

      // Distance preserves its entered km value and unit.
      final Map<String, Object?>? distSet = await harness.firstRow(
        'SELECT distance_entered, distance_unit, distance_scaled FROM set_logs '
        'WHERE distance_unit IS NOT NULL',
      );
      expect(distSet!['distance_entered'], 2.5);
      expect(distSet['distance_unit'], 'km');
      expect(distSet['distance_scaled'], 2500000);
    });

    test(
      'exposes underlying set records through the query service (R-FIT-004)',
      () async {
        await harness.service.logWorkoutSession(
          commandId: harness.nextCommandId('sess'),
          profileId: harness.profileId,
          sessionId: WorkoutSessionId('sess-1'),
          input: const LogWorkoutSessionInput(
            lifeAreaId: 'area-1',
            title: 'Morning Lift',
            startedAtUtc: 1000,
            exercises: <ExerciseLogInput>[
              ExerciseLogInput(
                name: 'Bench Press',
                rank: 'a',
                sets: <SetLogInput>[
                  SetLogInput(
                    rank: 'a',
                    reps: 5,
                    weightValue: 60,
                    weightUnit: 'kg',
                  ),
                ],
              ),
            ],
          ),
        );

        final List<WorkoutSession> sessions = await harness.queries
            .sessionHistory(harness.profileId.value, fromUtc: 0, toUtc: 100000);
        expect(sessions.single.title, 'Morning Lift');

        final List<ExerciseLog> exercises = await harness.queries
            .sessionExercises(harness.profileId.value, 'sess-1');
        final List<SetLog> sets = await harness.queries.exerciseSets(
          harness.profileId.value,
          exercises.single.id.value,
        );
        expect(sets.single.reps, 5);
        expect(sets.single.weight!.enteredValue, 60);
        expect(sets.single.weight!.enteredUnit, 'kg');
      },
    );

    test('rejects a set with a value but no unit', () async {
      final Result<Object> result = await harness.service.logWorkoutSession(
        commandId: harness.nextCommandId('sess'),
        profileId: harness.profileId,
        sessionId: WorkoutSessionId('sess-1'),
        input: const LogWorkoutSessionInput(
          lifeAreaId: 'area-1',
          title: 'Bad Lift',
          startedAtUtc: 1000,
          exercises: <ExerciseLogInput>[
            ExerciseLogInput(
              name: 'Bench Press',
              rank: 'a',
              sets: <SetLogInput>[SetLogInput(rank: 'a', weightValue: 60)],
            ),
          ],
        ),
      );

      expect(result, isA<Failed<Object>>());
      expect(
        (result as Failed<Object>).failure.code,
        'fitness.incomplete_measurement',
      );
      // The rolled-back transaction persisted nothing.
      expect(await harness.scalar('SELECT COUNT(*) FROM workout_sessions'), 0);
      expect(await harness.scalar('SELECT COUNT(*) FROM set_logs'), 0);
    });
  });

  group('recordBodyMeasurement (R-FIT-002, R-FIT-004)', () {
    test(
      'preserves entered value/unit and derives a canonical amount',
      () async {
        final Result<Object> result = await harness.service
            .recordBodyMeasurement(
              commandId: harness.nextCommandId('bw1'),
              profileId: harness.profileId,
              measurementId: BodyMeasurementId('bw-1'),
              input: const RecordBodyMeasurementInput(
                lifeAreaId: 'area-1',
                value: 80.5,
                unit: 'kg',
                measuredAtUtc: 1000,
              ),
            );

        expect(result, isA<Success<Object>>());
        final Map<String, Object?>? row = await harness.firstRow(
          'SELECT entered_value, entered_unit, value_scaled, kind '
          'FROM body_measurements',
        );
        expect(row!['entered_value'], 80.5);
        expect(row['entered_unit'], 'kg');
        expect(row['value_scaled'], 80500000);
        expect(row['kind'], 'weight');
      },
    );

    test('history and converted series expose the underlying record', () async {
      await harness.service.recordBodyMeasurement(
        commandId: harness.nextCommandId('bw1'),
        profileId: harness.profileId,
        measurementId: BodyMeasurementId('bw-1'),
        input: const RecordBodyMeasurementInput(
          lifeAreaId: 'area-1',
          value: 80,
          unit: 'kg',
          measuredAtUtc: 1000,
        ),
      );
      await harness.service.recordBodyMeasurement(
        commandId: harness.nextCommandId('bw2'),
        profileId: harness.profileId,
        measurementId: BodyMeasurementId('bw-2'),
        input: const RecordBodyMeasurementInput(
          lifeAreaId: 'area-1',
          value: 79.5,
          unit: 'kg',
          measuredAtUtc: 2000,
        ),
      );

      final List<BodyMeasurement> history = await harness.queries
          .bodyMeasurementHistory(
            harness.profileId.value,
            fromUtc: 0,
            toUtc: 100000,
          );
      // Newest first.
      expect(history.map((BodyMeasurement m) => m.measuredAtUtc), <int>[
        2000,
        1000,
      ]);

      // Converted to lb for a chart, oldest first, with the raw record attached.
      final List<BodyWeightPoint> series = await harness.queries
          .bodyWeightSeries(
            harness.profileId.value,
            fromUtc: 0,
            toUtc: 100000,
            displayUnit: 'lb',
          );
      expect(series.map((BodyWeightPoint p) => p.measuredAtUtc), <int>[
        1000,
        2000,
      ]);
      expect(series.first.displayUnit, 'lb');
      expect(series.first.displayValue, closeTo(176.37, 0.1));
      // The underlying record preserves the entered kg value (R-FIT-004).
      expect(series.first.source.value.enteredUnit, 'kg');
      expect(series.first.source.value.enteredValue, 80);
    });

    test('rejects a non-mass unit for body weight', () async {
      final Result<Object> result = await harness.service.recordBodyMeasurement(
        commandId: harness.nextCommandId('bad'),
        profileId: harness.profileId,
        measurementId: BodyMeasurementId('bw-1'),
        input: const RecordBodyMeasurementInput(
          lifeAreaId: 'area-1',
          value: 5,
          unit: 'km',
          measuredAtUtc: 1000,
        ),
      );

      expect(result, isA<Failed<Object>>());
      expect((result as Failed<Object>).failure.code, 'fitness.unit_not_mass');
    });
  });

  group('idempotency (R-GEN-005)', () {
    test('replaying the same command id returns the stored result', () async {
      final CommandId id = harness.nextCommandId('bw-replay');
      const RecordBodyMeasurementInput input = RecordBodyMeasurementInput(
        lifeAreaId: 'area-1',
        value: 80,
        unit: 'kg',
        measuredAtUtc: 1000,
      );
      final Result<Object> first = await harness.service.recordBodyMeasurement(
        commandId: id,
        profileId: harness.profileId,
        measurementId: BodyMeasurementId('bw-1'),
        input: input,
      );
      final Result<Object> second = await harness.service.recordBodyMeasurement(
        commandId: id,
        profileId: harness.profileId,
        measurementId: BodyMeasurementId('bw-1'),
        input: input,
      );

      expect(first, isA<Success<Object>>());
      expect(second, isA<Success<Object>>());
      // Only one row despite two calls.
      expect(await harness.scalar('SELECT COUNT(*) FROM body_measurements'), 1);
    });
  });
}
