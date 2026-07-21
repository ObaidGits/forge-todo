import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Maps stable wire values, progress surfaces, and failure codes to localized,
/// presentation-safe strings. Keeping this in one place ensures color is never
/// the sole signal (ux-design §5): every status always carries a text label,
/// and progress always carries its transparent formula (R-GOAL-004).
abstract final class GoalLabels {
  static String status(AppLocalizations l10n, GoalStatus status) =>
      switch (status) {
        GoalStatus.active => l10n.goalStatusActive,
        GoalStatus.onHold => l10n.goalStatusOnHold,
        GoalStatus.achieved => l10n.goalStatusAchieved,
        GoalStatus.abandoned => l10n.goalStatusAbandoned,
      };

  static String topicStatus(AppLocalizations l10n, RoadmapTopicStatus status) =>
      switch (status) {
        RoadmapTopicStatus.open => l10n.goalTopicStatusOpen,
        RoadmapTopicStatus.inProgress => l10n.goalTopicStatusInProgress,
        RoadmapTopicStatus.completed => l10n.goalTopicStatusCompleted,
        RoadmapTopicStatus.archived => l10n.goalTopicStatusArchived,
        RoadmapTopicStatus.cancelled => l10n.goalTopicStatusCancelled,
      };

  static String progressMode(AppLocalizations l10n, GoalProgressMode mode) =>
      switch (mode) {
        GoalProgressMode.manual => l10n.goalProgressManual,
        GoalProgressMode.derived => l10n.goalProgressDerived,
      };

  /// A short, screen-reader-friendly description of a progress surface: either
  /// a percentage or the neutral "not started" phrasing when no progress is
  /// computable (R-GOAL-004). Never renders a misleading 0%.
  static String progressValue(AppLocalizations l10n, GoalProgress progress) {
    if (!progress.isComputable) {
      return l10n.goalProgressNotStarted;
    }
    final int percent = (progress.value! * 100).round();
    return l10n.goalProgressPercent(percent);
  }

  /// A localized message for a stable [Failure] code, falling back to a generic
  /// message so an unmapped code never leaks a technical string.
  static String failure(AppLocalizations l10n, String code) => switch (code) {
    'goals.unavailable' => l10n.goalsUnavailable,
    'roadmap.already_exists' => l10n.goalRoadmapExists,
    _ when code.startsWith('roadmap.') => l10n.goalActionInvalid,
    _ when code.startsWith('goal.') => l10n.goalActionInvalid,
    _ => l10n.errorUnexpected,
  };
}
