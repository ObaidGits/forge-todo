import 'package:forge/core/domain/local_date.dart';

/// When a recurrence series stops generating occurrences (R-TASK-005).
///
/// A rule ends in exactly one documented way: it never ends, it ends on or
/// before an `UNTIL` date, or it ends after a fixed `COUNT` of occurrences.
/// Instances validate their own invariants so an illegal bound cannot exist.
sealed class RecurrenceEnd {
  const RecurrenceEnd();

  /// The series has no bound and generates forever.
  static const RecurrenceEnd never = NeverEnds._();

  /// The series stops after the last occurrence on or before [date].
  factory RecurrenceEnd.until(LocalDate date) = UntilDate;

  /// The series stops after generating [count] occurrences.
  factory RecurrenceEnd.count(int count) = CountLimit;
}

/// An unbounded series.
final class NeverEnds extends RecurrenceEnd {
  const NeverEnds._();

  @override
  bool operator ==(Object other) => other is NeverEnds;

  @override
  int get hashCode => (NeverEnds).hashCode;
}

/// A series bounded by an inclusive `UNTIL` local date.
final class UntilDate extends RecurrenceEnd {
  const UntilDate(this.date);

  final LocalDate date;

  @override
  bool operator ==(Object other) => other is UntilDate && other.date == date;

  @override
  int get hashCode => date.hashCode;
}

/// A series bounded by a total `COUNT` of generated occurrences.
final class CountLimit extends RecurrenceEnd {
  CountLimit(this.count) {
    if (count < 1) {
      throw FormatException('Recurrence count must be >= 1: $count');
    }
  }

  final int count;

  @override
  bool operator ==(Object other) => other is CountLimit && other.count == count;

  @override
  int get hashCode => count.hashCode;
}
