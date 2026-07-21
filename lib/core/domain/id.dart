abstract interface class IdGenerator {
  /// Returns the next RFC 9562 UUID version 7 value.
  String uuidV7();
}

/// Base type for opaque, strongly typed Forge identifiers.
abstract base class ForgeId {
  const ForgeId(this.value);

  final String value;

  static String validate(String value, String typeName) {
    if (!_validId.hasMatch(value)) {
      throw FormatException('Invalid $typeName.');
    }
    return value;
  }

  static final RegExp _validId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ForgeId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

final class ProfileId extends ForgeId {
  ProfileId(String value) : super(ForgeId.validate(value, 'ProfileId'));
}

final class LifeAreaId extends ForgeId {
  LifeAreaId(String value) : super(ForgeId.validate(value, 'LifeAreaId'));
}

final class CommandId extends ForgeId {
  CommandId(String value) : super(ForgeId.validate(value, 'CommandId'));
}

final class DeviceId extends ForgeId {
  DeviceId(String value) : super(ForgeId.validate(value, 'DeviceId'));
}

final class GenerationId extends ForgeId {
  GenerationId(String value) : super(ForgeId.validate(value, 'GenerationId'));
}

final class TaskId extends ForgeId {
  TaskId(String value) : super(ForgeId.validate(value, 'TaskId'));
}

final class NoteId extends ForgeId {
  NoteId(String value) : super(ForgeId.validate(value, 'NoteId'));
}

final class GoalId extends ForgeId {
  GoalId(String value) : super(ForgeId.validate(value, 'GoalId'));
}

final class MilestoneId extends ForgeId {
  MilestoneId(String value) : super(ForgeId.validate(value, 'MilestoneId'));
}

final class RoadmapId extends ForgeId {
  RoadmapId(String value) : super(ForgeId.validate(value, 'RoadmapId'));
}

final class RoadmapSectionId extends ForgeId {
  RoadmapSectionId(String value)
    : super(ForgeId.validate(value, 'RoadmapSectionId'));
}

final class RoadmapTopicId extends ForgeId {
  RoadmapTopicId(String value)
    : super(ForgeId.validate(value, 'RoadmapTopicId'));
}

final class ChecklistItemId extends ForgeId {
  ChecklistItemId(String value)
    : super(ForgeId.validate(value, 'ChecklistItemId'));
}

final class LearningResourceId extends ForgeId {
  LearningResourceId(String value)
    : super(ForgeId.validate(value, 'LearningResourceId'));
}

final class HabitId extends ForgeId {
  HabitId(String value) : super(ForgeId.validate(value, 'HabitId'));
}

final class ReminderId extends ForgeId {
  ReminderId(String value) : super(ForgeId.validate(value, 'ReminderId'));
}

final class PlanningPeriodId extends ForgeId {
  PlanningPeriodId(String value)
    : super(ForgeId.validate(value, 'PlanningPeriodId'));
}

final class FocusSessionId extends ForgeId {
  FocusSessionId(String value)
    : super(ForgeId.validate(value, 'FocusSessionId'));
}

final class WorkoutId extends ForgeId {
  WorkoutId(String value) : super(ForgeId.validate(value, 'WorkoutId'));
}

final class WorkoutTemplateId extends ForgeId {
  WorkoutTemplateId(String value)
    : super(ForgeId.validate(value, 'WorkoutTemplateId'));
}

final class TemplateExerciseId extends ForgeId {
  TemplateExerciseId(String value)
    : super(ForgeId.validate(value, 'TemplateExerciseId'));
}

final class WorkoutSessionId extends ForgeId {
  WorkoutSessionId(String value)
    : super(ForgeId.validate(value, 'WorkoutSessionId'));
}

final class ExerciseLogId extends ForgeId {
  ExerciseLogId(String value) : super(ForgeId.validate(value, 'ExerciseLogId'));
}

final class SetLogId extends ForgeId {
  SetLogId(String value) : super(ForgeId.validate(value, 'SetLogId'));
}

final class BodyMeasurementId extends ForgeId {
  BodyMeasurementId(String value)
    : super(ForgeId.validate(value, 'BodyMeasurementId'));
}

final class WaterEventId extends ForgeId {
  WaterEventId(String value) : super(ForgeId.validate(value, 'WaterEventId'));
}

final class FilterId extends ForgeId {
  FilterId(String value) : super(ForgeId.validate(value, 'FilterId'));
}

final class AttachmentId extends ForgeId {
  AttachmentId(String value) : super(ForgeId.validate(value, 'AttachmentId'));
}
