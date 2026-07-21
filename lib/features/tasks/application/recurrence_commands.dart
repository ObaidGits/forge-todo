import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';

/// Input to attach or replace the recurrence of a task (R-TASK-005).
///
/// Setting a recurrence creates the first immutable schedule version of a
/// series and materializes its first occurrence. The task's due/scheduled state
/// is aligned to that first occurrence.
final class SetRecurrenceInput {
  const SetRecurrenceInput({required this.rule});

  /// The RFC-5545-compatible rule defining the series.
  final RecurrenceRule rule;
}

/// Input to edit the recurrence of an existing series from a given occurrence
/// (R-TASK-007).
final class EditRecurrenceInput {
  const EditRecurrenceInput({
    required this.scope,
    required this.fromOccurrenceKey,
    this.newRule,
  });

  /// Whether the edit applies to only [fromOccurrenceKey] or that occurrence
  /// and all future occurrences.
  final RecurrenceEditScope scope;

  /// The occurrence key the edit is anchored at.
  final LocalDate fromOccurrenceKey;

  /// The replacement rule for a "this and future" edit. Required for
  /// [RecurrenceEditScope.thisAndFuture]; ignored for
  /// [RecurrenceEditScope.thisOccurrence], which only excludes the occurrence.
  final RecurrenceRule? newRule;
}
