import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';

/// The durable fitness command surface (R-FIT-001, R-FIT-002, R-GEN-005).
///
/// Every method commits one atomic transaction through the command bus and
/// returns the stable committed result. [commandId] makes each call idempotent:
/// replaying the same id with the same request returns the stored result; a
/// different request under the same id is rejected as a conflict.
abstract interface class FitnessCommandService {
  /// Creates a workout template and its ordered planned exercises (R-FIT-001).
  Future<Result<CommittedCommandResult>> createWorkoutTemplate({
    required CommandId commandId,
    required ProfileId profileId,
    required WorkoutTemplateId templateId,
    required CreateWorkoutTemplateInput input,
  });

  /// Logs a workout session with its exercises and sets, preserving each
  /// entered weight/distance unit while storing a canonical amount (R-FIT-001,
  /// R-FIT-002).
  Future<Result<CommittedCommandResult>> logWorkoutSession({
    required CommandId commandId,
    required ProfileId profileId,
    required WorkoutSessionId sessionId,
    required LogWorkoutSessionInput input,
  });

  /// Records a body-weight measurement, preserving the entered value/unit and
  /// storing a canonical amount for computation (R-FIT-002).
  Future<Result<CommittedCommandResult>> recordBodyMeasurement({
    required CommandId commandId,
    required ProfileId profileId,
    required BodyMeasurementId measurementId,
    required RecordBodyMeasurementInput input,
  });

  /// Logs an optional water-intake event, preserving the entered value/unit and
  /// storing a canonical amount for computation (R-FIT-003).
  ///
  /// Water tracking is disabled by default; when it is disabled for the profile
  /// this returns a `fitness.water_disabled` validation failure and writes
  /// nothing, so no water logging surfaces until the local preference is
  /// explicitly enabled.
  Future<Result<CommittedCommandResult>> logWaterEvent({
    required CommandId commandId,
    required ProfileId profileId,
    required WaterEventId eventId,
    required LogWaterEventInput input,
  });
}
