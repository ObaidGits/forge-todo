import 'package:forge/features/habits/domain/habit_checkin.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// The derived projection of a single habit occurrence (R-HABIT-003).
final class HabitProjection {
  const HabitProjection({
    required this.status,
    required this.normalizedTotal,
    required this.met,
    required this.hasViolation,
  });

  final HabitOccurrenceStatus status;

  /// The accumulated normalized total for numeric kinds (0 otherwise).
  final int normalizedTotal;

  /// Whether the target condition is met right now (ignoring close for numeric
  /// and boolean; for abstinence, met means "no violation").
  final bool met;

  /// Whether any non-superseded violation exists (abstinence only).
  final bool hasViolation;
}

/// Pure derivation of an occurrence's current projection from its non-superseded
/// check-ins and close/pause state (R-HABIT-003, R-HABIT-002).
///
/// * numeric kinds complete when the normalized total meets the bound version's
///   `target_value`;
/// * boolean completes on an explicit true observation;
/// * abstinence becomes missed on the first non-superseded violation and
///   completes only when its dated occurrence or aggregate period closes with
///   no violation (until close it stays open).
///
/// A `skipped` or `paused` occurrence is decided by the caller and is not
/// re-derived here; this policy is concerned only with target satisfaction.
abstract final class HabitProjectionPolicy {
  /// Derives the projection for [target] over the current [observations].
  ///
  /// [isClosed] is whether the occurrence's dated day / aggregate period has
  /// closed. Numeric and boolean occurrences complete as soon as the target is
  /// met regardless of close; when closed without meeting the target they are
  /// `missed`. Abstinence completes only on close with no violation.
  static HabitProjection project({
    required HabitTarget target,
    required List<HabitObservation> observations,
    required bool isClosed,
  }) {
    switch (target.kind) {
      case HabitTargetKind.boolean:
        final bool anyTrue = observations.any(
          (HabitObservation o) => o.kind == HabitCheckinKind.booleanTrue,
        );
        return HabitProjection(
          status: anyTrue
              ? HabitOccurrenceStatus.completed
              : (isClosed
                    ? HabitOccurrenceStatus.missed
                    : HabitOccurrenceStatus.open),
          normalizedTotal: 0,
          met: anyTrue,
          hasViolation: false,
        );
      case HabitTargetKind.count:
      case HabitTargetKind.duration:
      case HabitTargetKind.quantity:
        int total = 0;
        for (final HabitObservation o in observations) {
          if (o.kind == HabitCheckinKind.value) {
            total += o.normalizedValue;
          }
        }
        final int target0 = target.targetValue ?? 0;
        final bool met = total >= target0;
        return HabitProjection(
          status: met
              ? HabitOccurrenceStatus.completed
              : (isClosed
                    ? HabitOccurrenceStatus.missed
                    : HabitOccurrenceStatus.open),
          normalizedTotal: total,
          met: met,
          hasViolation: false,
        );
      case HabitTargetKind.abstinence:
        final bool hasViolation = observations.any(
          (HabitObservation o) => o.kind == HabitCheckinKind.violation,
        );
        final HabitOccurrenceStatus status;
        if (hasViolation) {
          status = HabitOccurrenceStatus.missed;
        } else if (isClosed) {
          status = HabitOccurrenceStatus.completed;
        } else {
          status = HabitOccurrenceStatus.open;
        }
        return HabitProjection(
          status: status,
          normalizedTotal: 0,
          met: !hasViolation,
          hasViolation: hasViolation,
        );
    }
  }
}
