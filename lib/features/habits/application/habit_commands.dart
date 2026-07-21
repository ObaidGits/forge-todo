import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// Input to create a habit with its first immutable schedule + target version
/// (R-HABIT-001, R-HABIT-002).
final class CreateHabitInput {
  const CreateHabitInput({
    required this.lifeAreaId,
    required this.title,
    required this.rule,
    required this.target,
    required this.rank,
  });

  final String lifeAreaId;
  final String title;
  final HabitScheduleRule rule;
  final HabitTarget target;
  final String rank;
}

/// The kind of an observation the caller is recording (R-HABIT-002).
enum ObservationInputKind {
  /// A boolean true check-in (boolean target).
  booleanTrue,

  /// A numeric contribution (count/duration/quantity target).
  value,

  /// An abstinence violation.
  violation,

  /// A correction that retracts a prior abstinence violation, clearing it so
  /// the occurrence is no longer missed (R-HABIT-005). Only valid on an
  /// abstinence target and only via [CorrectObservationInput]; the superseded
  /// violation stays in the append-only audit log.
  clearViolation,
}

/// Input to record an append-only check-in against a habit occurrence
/// (R-HABIT-003, R-HABIT-005).
///
/// The occurrence is identified by the local date the check-in applies to; the
/// service resolves the deterministic occurrence key (dated or aggregate) from
/// the schedule version effective at that key. For a numeric target [rawValue]
/// is provided in [rawUnit] (quantity) or the target display unit (duration);
/// count observations default to a raw value of 1 when omitted.
final class CheckInInput {
  const CheckInInput({
    required this.onDate,
    required this.kind,
    this.rawValue,
    this.rawUnit,
    this.note,
  });

  final LocalDate onDate;
  final ObservationInputKind kind;
  final num? rawValue;
  final String? rawUnit;
  final String? note;
}

/// Input to correct a prior observation by superseding it (R-HABIT-005).
final class CorrectObservationInput {
  const CorrectObservationInput({
    required this.logicalId,
    required this.kind,
    this.rawValue,
    this.rawUnit,
    this.note,
  });

  /// The logical observation id whose current record is superseded.
  final String logicalId;
  final ObservationInputKind kind;
  final num? rawValue;
  final String? rawUnit;
  final String? note;
}

/// Input to skip an occurrence with a reason (R-HABIT-004, R-HABIT-005).
final class SkipOccurrenceInput {
  const SkipOccurrenceInput({required this.onDate, this.reason});

  final LocalDate onDate;
  final String? reason;
}

/// Input to close a dated occurrence or aggregate period (R-HABIT-002,
/// R-HABIT-003). Closing finalizes the projection: numeric/boolean occurrences
/// become missed if unmet, and abstinence completes when no violation exists.
final class CloseOccurrenceInput {
  const CloseOccurrenceInput({required this.onDate});

  final LocalDate onDate;
}

/// Input to edit a habit's schedule/target "this and future" (R-HABIT-003). A
/// successor version is created at [effectiveKey]; prior occurrences are never
/// reinterpreted.
final class EditScheduleInput {
  const EditScheduleInput({
    required this.effectiveKey,
    required this.rule,
    required this.target,
  });

  final LocalDate effectiveKey;
  final HabitScheduleRule rule;
  final HabitTarget target;
}

/// Input to pause a habit from [startDate] (R-HABIT-005).
final class PauseHabitInput {
  const PauseHabitInput({required this.startDate, this.endDate, this.reason});

  final LocalDate startDate;
  final LocalDate? endDate;
  final String? reason;
}
