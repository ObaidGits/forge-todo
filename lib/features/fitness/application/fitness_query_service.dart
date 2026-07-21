import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';

/// One point in a body-weight series (R-FIT-002, R-FIT-004).
///
/// The point carries BOTH the value converted into the requested display unit
/// (for a chart) AND the underlying measurement it came from, so the exact
/// entered value/unit is always available beneath any chart — no medical
/// interpretation is added (R-FIT-004).
final class BodyWeightPoint {
  const BodyWeightPoint({
    required this.measuredAtUtc,
    required this.displayValue,
    required this.displayUnit,
    required this.source,
  });

  final int measuredAtUtc;
  final double displayValue;
  final String displayUnit;

  /// The underlying measurement record, exposed alongside the chart value.
  final BodyMeasurement source;
}

/// The fitness read/query surface (R-FIT-001, R-FIT-002, R-FIT-004).
abstract interface class FitnessQueryService {
  /// Active workout templates for the profile, rank-ordered.
  Future<List<WorkoutTemplate>> workoutTemplates(String profileId);

  /// The single logged workout session [sessionId], or null when absent/deleted
  /// for the profile. Exposes the underlying record behind a `/fitness/<id>`
  /// deep link (R-FIT-001, R-FIT-004).
  Future<WorkoutSession?> findWorkoutSession(
    String profileId,
    String sessionId,
  );

  /// Workout-session history within an inclusive UTC-micros window, newest
  /// first.
  Future<List<WorkoutSession>> sessionHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  });

  /// The exercises performed in a session, rank-ordered (underlying records).
  Future<List<ExerciseLog>> sessionExercises(
    String profileId,
    String sessionId,
  );

  /// The sets performed in an exercise log, rank-ordered (underlying records).
  Future<List<SetLog>> exerciseSets(String profileId, String exerciseLogId);

  /// Raw body-weight measurement history, newest first, preserving entered
  /// value/unit.
  Future<List<BodyMeasurement>> bodyMeasurementHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  });

  /// A body-weight series converted into [displayUnit] for charting, oldest
  /// first, each point exposing its underlying record (R-FIT-004).
  Future<List<BodyWeightPoint>> bodyWeightSeries(
    String profileId, {
    required int fromUtc,
    required int toUtc,
    required String displayUnit,
  });

  /// Whether optional water tracking is enabled for the profile. Defaults to
  /// `false` (disabled) when no preference has been stored (R-FIT-003). A
  /// water UI should only surface when this is `true`.
  Future<bool> isWaterTrackingEnabled(String profileId);

  /// Raw water-event history within an inclusive UTC-micros window, newest
  /// first, preserving each entered value/unit (R-FIT-003). History survives
  /// disabling water tracking, so re-enabling never loses past records.
  Future<List<WaterEvent>> waterEventHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  });
}
