import 'package:forge/l10n/generated/app_localizations.dart';

/// Maps stable wire values and failure codes to localized, presentation-safe
/// strings. Keeping this in one place ensures color is never the sole signal
/// (ux-design §5): every status/priority always carries a text label.
abstract final class TaskLabels {
  static String priority(AppLocalizations l10n, String wire) => switch (wire) {
    'low' => l10n.priorityLow,
    'medium' => l10n.priorityMedium,
    'high' => l10n.priorityHigh,
    'urgent' => l10n.priorityUrgent,
    _ => l10n.priorityNone,
  };

  static String status(AppLocalizations l10n, String wire) => switch (wire) {
    'in_progress' => l10n.statusInProgress,
    'completed' => l10n.statusCompleted,
    'cancelled' => l10n.statusCancelled,
    _ => l10n.statusOpen,
  };

  static String view(AppLocalizations l10n, String wire) => switch (wire) {
    'upcoming' => l10n.taskViewUpcoming,
    'inbox' => l10n.taskViewInbox,
    'completed' => l10n.taskViewCompleted,
    'trash' => l10n.taskViewTrash,
    _ => l10n.taskViewToday,
  };

  /// A localized message for a stable [Failure] code, falling back to a generic
  /// message so an unmapped code never leaks a technical string.
  static String failure(AppLocalizations l10n, String code) => switch (code) {
    'task.not_found' => l10n.errorTaskNotFound,
    'tasks.unavailable' => l10n.tasksUnavailable,
    'purge.blocked' => l10n.errorPurgeBlocked,
    'purge.confirmation_mismatch' => l10n.errorPurgeReconfirm,
    'task.hierarchy_cycle' ||
    'task.hierarchy_too_deep' => l10n.errorTaskHierarchy,
    _ when code.startsWith('task.') => l10n.errorTaskInvalid,
    _ => l10n.errorUnexpected,
  };
}
