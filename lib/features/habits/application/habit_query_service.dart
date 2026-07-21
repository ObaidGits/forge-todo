import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';

/// Presentation-safe read projections for the habits UI (R-HOME-001,
/// R-HABIT-005, R-HABIT-006, R-HABIT-007).
///
/// This is the habits feature's *exported application contract*. Screens and
/// other features (for example Home) compose it without importing the habits
/// Drift infrastructure or reaching into the domain occurrence engine directly
/// (design.md §4). Every field is a primitive or a plain value type so a
/// consumer never needs an infrastructure import. All reads run against the
/// active local generation, so the surface is always available offline
/// (R-GEN-001).

/// The kind of a habit target, as a presentation-safe wire value.
///
/// Mirrors the domain `HabitTargetKind` wire values so the UI can decide how to
/// render a check-in control without importing the domain target type.
const String kHabitTargetBoolean = 'boolean';
const String kHabitTargetCount = 'count';
const String kHabitTargetDuration = 'duration';
const String kHabitTargetQuantity = 'quantity';
const String kHabitTargetAbstinence = 'abstinence';

/// A single habit's today occurrence, everything a check-in row needs
/// (R-HOME-001, R-HABIT-003).
final class HabitTodayEntry {
  const HabitTodayEntry({
    required this.habitId,
    required this.title,
    required this.onDateIso,
    required this.occurrenceKey,
    required this.statusWire,
    required this.targetKindWire,
    required this.normalizedTotal,
    required this.isPaused,
    this.targetValue,
    this.unit,
    this.displayUnit,
  });

  final String habitId;
  final String title;

  /// The local date (`YYYY-MM-DD`) this entry's occurrence applies to.
  final String onDateIso;

  /// The deterministic occurrence key (dated ISO date or `week`/`month` key).
  final String occurrenceKey;

  /// Stable occurrence status wire value: `open`, `completed`, `missed`,
  /// `skipped`.
  final String statusWire;

  /// Stable target-kind wire value used to pick the check-in control.
  final String targetKindWire;

  /// Accumulated normalized total for numeric kinds (0 otherwise).
  final int normalizedTotal;

  /// True when this occurrence's anchor is paused; the UI shows a neutral
  /// paused chip and never treats it as a miss (R-HABIT-004).
  final bool isPaused;

  /// The numeric target (canonical seconds for duration, canonical units for
  /// quantity, positive integer for count); null for boolean/abstinence.
  final int? targetValue;

  /// The required unit for a quantity target; null otherwise.
  final String? unit;

  /// The preserved display unit for a duration target; null otherwise.
  final String? displayUnit;

  bool get isCompleted => statusWire == 'completed';
  bool get isSkipped => statusWire == 'skipped';
  bool get isNumeric =>
      targetKindWire == kHabitTargetCount ||
      targetKindWire == kHabitTargetDuration ||
      targetKindWire == kHabitTargetQuantity;
}

/// A single materialized occurrence for the history / calendar surfaces
/// (R-HABIT-003, R-HABIT-004).
final class HabitOccurrenceView {
  const HabitOccurrenceView({
    required this.occurrenceKey,
    required this.anchorIso,
    required this.statusWire,
    required this.normalizedTotal,
    required this.isPaused,
  });

  final String occurrenceKey;

  /// The occurrence anchor local date (`YYYY-MM-DD`).
  final String anchorIso;

  /// Stable occurrence status wire value.
  final String statusWire;
  final int normalizedTotal;
  final bool isPaused;

  /// The metric-relevant outcome under metric policy v1, so history/calendar
  /// can render exactly what the streak/consistency computation sees.
  HabitPeriodOutcome get outcome {
    if (isPaused) {
      return HabitPeriodOutcome.paused;
    }
    return switch (statusWire) {
      'completed' => HabitPeriodOutcome.completed,
      'missed' => HabitPeriodOutcome.missed,
      'skipped' => HabitPeriodOutcome.skipped,
      _ => HabitPeriodOutcome.open,
    };
  }
}

/// One calendar month of habit occurrences keyed by anchor date (ux-design §8).
final class HabitCalendarMonth {
  const HabitCalendarMonth({
    required this.year,
    required this.month,
    required this.occurrencesByDayIso,
  });

  final int year;
  final int month;

  /// Occurrences in the month, keyed by their anchor `YYYY-MM-DD`. Aggregate
  /// (week/month) occurrences are keyed by their anchor day.
  final Map<String, HabitOccurrenceView> occurrencesByDayIso;
}

/// Transparent streak + consistency statistics under metric policy v1
/// (R-HABIT-004, R-HABIT-007).
///
/// Consistency carries its numerator/denominator so the UI can render the exact
/// formula and show "no eligible data" for a zero denominator rather than a
/// misleading 0% (R-HABIT-007).
final class HabitStatistics {
  const HabitStatistics({
    required this.currentStreak,
    required this.consistency,
    required this.fromIso,
    required this.toIso,
    this.metricPolicyVersion = kHabitMetricPolicyVersion,
  });

  final int currentStreak;
  final HabitConsistency consistency;

  /// Inclusive range the statistics were computed over.
  final String fromIso;
  final String toIso;

  /// The displayed metric-policy version tag (R-HABIT-007).
  final String metricPolicyVersion;

  bool get hasData => consistency.hasData;
}

/// The projected metric impact of a backfilled or corrected check-in before it
/// is committed (R-HABIT-005).
///
/// It states the streak and consistency both before and after the hypothetical
/// change so the user can preview the effect. It is a pure projection of period
/// outcomes and never mutates anything.
final class HabitImpactPreview {
  const HabitImpactPreview({
    required this.streakBefore,
    required this.streakAfter,
    required this.consistencyBefore,
    required this.consistencyAfter,
    this.metricPolicyVersion = kHabitMetricPolicyVersion,
  });

  final int streakBefore;
  final int streakAfter;
  final HabitConsistency consistencyBefore;
  final HabitConsistency consistencyAfter;
  final String metricPolicyVersion;

  int get streakDelta => streakAfter - streakBefore;
}

/// The metric-relevant outcome the user is previewing for the backfilled or
/// corrected occurrence (R-HABIT-005). Mirrors the decisive domain outcomes a
/// check-in can produce.
enum HabitPreviewOutcome {
  completed,
  missed,
  skipped;

  HabitPeriodOutcome get asPeriodOutcome => switch (this) {
    HabitPreviewOutcome.completed => HabitPeriodOutcome.completed,
    HabitPreviewOutcome.missed => HabitPeriodOutcome.missed,
    HabitPreviewOutcome.skipped => HabitPeriodOutcome.skipped,
  };
}

/// A lightweight descriptive projection of a habit for a detail header
/// (R-HABIT-001, R-HABIT-002). It carries just enough to title the detail
/// surface and describe its target without a domain import.
final class HabitSummary {
  const HabitSummary({
    required this.habitId,
    required this.title,
    required this.targetKindWire,
    required this.isPaused,
    this.targetValue,
    this.unit,
    this.displayUnit,
  });

  final String habitId;
  final String title;
  final String targetKindWire;
  final bool isPaused;
  final int? targetValue;
  final String? unit;
  final String? displayUnit;
}

/// Exported read contract for the habits presentation surfaces (R-HOME-001,
/// R-HABIT-004, R-HABIT-005, R-HABIT-007).
abstract interface class HabitQueryService {
  /// A descriptive summary for [habitId], or null when it does not exist for
  /// [profileId]. Used to title and describe the detail surface.
  Future<HabitSummary?> summary({
    required ProfileId profileId,
    required HabitId habitId,
  });

  /// The Today habit checklist for [profileId] on [onDate]: one entry per
  /// active habit whose schedule has a scheduled occurrence on that date
  /// (R-HOME-001). Habits with no occurrence on the date are omitted, so the
  /// section collapses cleanly when nothing is due (R-HOME-002).
  Future<List<HabitTodayEntry>> todayChecklist({
    required ProfileId profileId,
    required LocalDate onDate,
  });

  /// The habit's materialized occurrences within the inclusive `[from, to]`
  /// window, newest first (R-HABIT-003). Returns an empty list for an unknown
  /// habit.
  Future<List<HabitOccurrenceView>> history({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
  });

  /// The habit's occurrences within [year]/[month], keyed by anchor day, for
  /// the calendar view (ux-design §8).
  Future<HabitCalendarMonth> calendarMonth({
    required ProfileId profileId,
    required HabitId habitId,
    required int year,
    required int month,
  });

  /// The transparent streak + consistency statistics for [habitId] over the
  /// inclusive `[from, to]` window under metric policy v1 (R-HABIT-004,
  /// R-HABIT-007).
  Future<HabitStatistics> statistics({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
  });

  /// The projected metric impact of backfilling or correcting the occurrence on
  /// [onDate] to [outcome], evaluated over the inclusive `[from, to]` window
  /// without committing anything (R-HABIT-005).
  Future<HabitImpactPreview> impactPreview({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
    required LocalDate onDate,
    required HabitPreviewOutcome outcome,
  });
}
