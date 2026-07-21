import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/application/fitness_query_service.dart';
import 'package:forge/features/fitness/application/water_tracking_settings.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/infrastructure/fitness_read_repository.dart';

/// Drift-backed implementation of [FitnessQueryService] (R-FIT-001, R-FIT-002,
/// R-FIT-004).
///
/// The chart-oriented [bodyWeightSeries] converts each measurement into the
/// requested display unit while carrying the underlying record, so a chart
/// never hides the exact entered value and no medical interpretation is applied.
final class DriftFitnessQueryService implements FitnessQueryService {
  DriftFitnessQueryService(this._reads, this._water);

  final FitnessReadRepository _reads;
  final WaterTrackingSettings _water;

  @override
  Future<List<WorkoutTemplate>> workoutTemplates(String profileId) =>
      _reads.templates(profileId);

  @override
  Future<WorkoutSession?> findWorkoutSession(
    String profileId,
    String sessionId,
  ) => _reads.findSession(profileId, sessionId);

  @override
  Future<List<WorkoutSession>> sessionHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) => _reads.sessionHistory(profileId, fromUtc: fromUtc, toUtc: toUtc);

  @override
  Future<List<ExerciseLog>> sessionExercises(
    String profileId,
    String sessionId,
  ) => _reads.exerciseLogs(profileId, sessionId);

  @override
  Future<List<SetLog>> exerciseSets(String profileId, String exerciseLogId) =>
      _reads.setLogs(profileId, exerciseLogId);

  @override
  Future<List<BodyMeasurement>> bodyMeasurementHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) => _reads.measurementHistory(profileId, fromUtc: fromUtc, toUtc: toUtc);

  @override
  Future<List<BodyWeightPoint>> bodyWeightSeries(
    String profileId, {
    required int fromUtc,
    required int toUtc,
    required String displayUnit,
  }) async {
    final List<BodyMeasurement> measurements = await _reads.measurementHistory(
      profileId,
      fromUtc: fromUtc,
      toUtc: toUtc,
    );
    // Oldest-first for a left-to-right trend; the raw record travels with each
    // point so the underlying value is always accessible (R-FIT-004).
    final List<BodyMeasurement> ordered = measurements.reversed.toList(
      growable: false,
    );
    return <BodyWeightPoint>[
      for (final BodyMeasurement m in ordered)
        BodyWeightPoint(
          measuredAtUtc: m.measuredAtUtc,
          displayValue: m.value.displayIn(displayUnit),
          displayUnit: displayUnit,
          source: m,
        ),
    ];
  }

  @override
  Future<bool> isWaterTrackingEnabled(String profileId) =>
      _water.isEnabled(ProfileId(profileId));

  @override
  Future<List<WaterEvent>> waterEventHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) => _reads.waterEventHistory(profileId, fromUtc: fromUtc, toUtc: toUtc);
}
