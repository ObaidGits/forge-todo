/// The due form of a task (R-TASK-004).
///
/// A task has *either* a floating local [DateDue] (`due_date`) *or* an absolute
/// [InstantDue] (`due_at` UTC instant plus display timezone), never both. The
/// absence of a due form is [NoDue]. `scheduled_date` is tracked independently
/// on the entity and is not part of the due form.
///
/// Instances are immutable and validate their own invariants at construction so
/// an illegal due form cannot exist in the domain.
sealed class TaskDue {
  const TaskDue();

  /// A task with no due form.
  static const TaskDue none = NoDue._();

  /// A floating local calendar date (`YYYY-MM-DD`).
  factory TaskDue.onDate(String isoDate) = DateDue;

  /// An absolute instant in UTC microseconds plus its display timezone.
  factory TaskDue.atInstant({
    required int utcMicros,
    required String timezoneId,
  }) = InstantDue;

  /// The floating date, or null when this is not a [DateDue].
  String? get dueDate => switch (this) {
    DateDue(:final String date) => date,
    _ => null,
  };

  /// The UTC-microsecond instant, or null when this is not an [InstantDue].
  int? get dueAtUtc => switch (this) {
    InstantDue(:final int utcMicros) => utcMicros,
    _ => null,
  };

  /// The display timezone, or null when this is not an [InstantDue].
  String? get timezoneId => switch (this) {
    InstantDue(:final String timezoneId) => timezoneId,
    _ => null,
  };

  bool get hasDue => this is! NoDue;
}

/// The absence of a due form.
final class NoDue extends TaskDue {
  const NoDue._();
}

/// A floating local calendar date with no time-of-day or timezone.
final class DateDue extends TaskDue {
  DateDue(this.date) {
    if (!_isoDate.hasMatch(date)) {
      throw FormatException('due_date must be ISO YYYY-MM-DD: $date');
    }
  }

  final String date;

  static final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  @override
  bool operator ==(Object other) => other is DateDue && other.date == date;

  @override
  int get hashCode => date.hashCode;
}

/// An absolute instant paired with the timezone it should be displayed in.
final class InstantDue extends TaskDue {
  InstantDue({required this.utcMicros, required this.timezoneId}) {
    if (timezoneId.isEmpty) {
      throw const FormatException('due_at requires a non-empty timezone id.');
    }
  }

  final int utcMicros;

  @override
  final String timezoneId;

  @override
  bool operator ==(Object other) =>
      other is InstantDue &&
      other.utcMicros == utcMicros &&
      other.timezoneId == timezoneId;

  @override
  int get hashCode => Object.hash(utcMicros, timezoneId);
}
