import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Maps habit wire values and metric surfaces to localized, presentation-safe
/// strings. Keeping this in one place ensures color is never the sole signal
/// (ux-design §5): every status carries a text label, and the copy is neutral
/// and non-shaming — a miss is described factually, never as a personal failure
/// (R-HABIT-006).
abstract final class HabitLabels {
  /// A neutral label for an occurrence status wire value. A missed occurrence
  /// reads as "Not logged", never guilt language (R-HABIT-006).
  static String occurrenceStatus(
    AppLocalizations l10n,
    String statusWire, {
    bool isPaused = false,
  }) {
    if (isPaused) {
      return l10n.habitStatusPaused;
    }
    return switch (statusWire) {
      'completed' => l10n.habitStatusDone,
      'missed' => l10n.habitStatusNotLogged,
      'skipped' => l10n.habitStatusSkipped,
      _ => l10n.habitStatusOpen,
    };
  }

  /// A neutral label for a metric-policy period outcome, used by the impact
  /// preview and the history/calendar legends.
  static String periodOutcome(AppLocalizations l10n, HabitPeriodOutcome o) =>
      switch (o) {
        HabitPeriodOutcome.completed => l10n.habitStatusDone,
        HabitPeriodOutcome.missed => l10n.habitStatusNotLogged,
        HabitPeriodOutcome.skipped => l10n.habitStatusSkipped,
        HabitPeriodOutcome.paused => l10n.habitStatusPaused,
        HabitPeriodOutcome.open => l10n.habitStatusOpen,
      };

  static String previewOutcome(AppLocalizations l10n, HabitPreviewOutcome o) =>
      switch (o) {
        HabitPreviewOutcome.completed => l10n.habitStatusDone,
        HabitPreviewOutcome.missed => l10n.habitStatusNotLogged,
        HabitPreviewOutcome.skipped => l10n.habitStatusSkipped,
      };

  /// A screen-reader-friendly description of a numeric target's progress, or an
  /// empty string for non-numeric kinds.
  static String targetProgress(AppLocalizations l10n, HabitTodayEntry entry) {
    if (!entry.isNumeric || entry.targetValue == null) {
      return '';
    }
    final String unit = _unitLabel(entry.targetKindWire, entry);
    return l10n.habitTargetProgress(
      entry.normalizedTotal,
      entry.targetValue!,
      unit,
    );
  }

  /// The transparent consistency label: the exact numerator/denominator and a
  /// percentage, or the neutral "no eligible data" phrasing for a zero
  /// denominator — never a misleading 0% (R-HABIT-007).
  static String consistency(AppLocalizations l10n, HabitConsistency c) {
    if (!c.hasData) {
      return l10n.habitConsistencyNoData;
    }
    final int percent = ((c.ratio ?? 0) * 100).round();
    return l10n.habitConsistencyValue(c.completed, c.denominator, percent);
  }

  /// The displayed metric-policy version tag shown alongside every metric
  /// (R-HABIT-007).
  static String metricPolicy(AppLocalizations l10n, String version) =>
      l10n.habitMetricPolicy(version);

  /// A localized, presentation-safe message for a stable failure code.
  static String failure(AppLocalizations l10n, String code) => switch (code) {
    'habits.unavailable' => l10n.habitsUnavailable,
    _ when code.startsWith('habit.') => l10n.habitActionInvalid,
    _ => l10n.errorUnexpected,
  };

  static String feedback(AppLocalizations l10n, String messageCode) =>
      switch (messageCode) {
        'checkedIn' => l10n.habitCheckedIn,
        'skipped' => l10n.habitSkippedConfirm,
        'corrected' => l10n.habitCorrectedConfirm,
        _ => l10n.habitCheckedIn,
      };

  static String _unitLabel(String targetKindWire, HabitTodayEntry entry) {
    return switch (targetKindWire) {
      kHabitTargetDuration => entry.displayUnit ?? 'seconds',
      kHabitTargetQuantity => entry.unit ?? '',
      _ => '',
    };
  }
}
