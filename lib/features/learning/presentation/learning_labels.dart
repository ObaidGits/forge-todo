import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Localized, accessible labels for the learning presentation surfaces. Keeping
/// the mapping here means the screens never branch on wire strings and color is
/// never the sole carrier of meaning (`NFR-A11Y-003`).
abstract final class LearningLabels {
  /// The user-facing name of a Learning Resource type. Forge presents a single
  /// "Learning Resource" umbrella, so `course` is one type among several and is
  /// never surfaced as "course" specifically (R-LEARN-001).
  static String resourceType(AppLocalizations l10n, LearningResourceType type) {
    return switch (type) {
      LearningResourceType.course => l10n.learnTypeCourse,
      LearningResourceType.book => l10n.learnTypeBook,
      LearningResourceType.playlist => l10n.learnTypePlaylist,
      LearningResourceType.article => l10n.learnTypeArticle,
      LearningResourceType.other => l10n.learnTypeOther,
    };
  }

  /// The user-facing lifecycle status of a Learning Resource (R-LEARN-001).
  static String status(AppLocalizations l10n, LearningResourceStatus status) {
    return switch (status) {
      LearningResourceStatus.active => l10n.learnStatusActive,
      LearningResourceStatus.completed => l10n.learnStatusCompleted,
      LearningResourceStatus.onHold => l10n.learnStatusOnHold,
      LearningResourceStatus.archived => l10n.learnStatusArchived,
    };
  }

  /// A short, screen-reader-friendly description of transparent progress: a
  /// rounded percentage, or the neutral "not started" phrasing when no progress
  /// is computable (R-LEARN-004). Never renders a misleading 0%.
  static String progress(AppLocalizations l10n, LearningProgress progress) {
    if (!progress.isStarted) {
      return l10n.learnProgressNotStarted;
    }
    final int percent = (progress.fraction * 100).round();
    return l10n.learnProgressPercent(percent);
  }
}
