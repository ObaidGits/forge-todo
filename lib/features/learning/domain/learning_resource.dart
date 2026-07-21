import 'package:forge/core/domain/id.dart';
import 'package:forge/features/learning/domain/edit_sentinel.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';

/// An immutable Learning Resource aggregate (R-LEARN-001).
///
/// A Learning Resource is a top-level direct-area owner: it carries its profile
/// and Life Area, a user-facing [type], an optional source URL and creator, a
/// [status], and a progress configuration. Its ordered sections/items live in
/// separate `learning_items` rows; its notes are a canonical note reference
/// (`noteId`) rather than a second text system (R-LEARN-001, R-NOTE-002).
final class LearningResource {
  LearningResource({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.title,
    required this.type,
    required this.status,
    required this.progressMode,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.sourceUri,
    this.creator,
    this.noteId,
    this.manualProgressPermille,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Learning Resource title must not be empty.');
    }
    final int? permille = manualProgressPermille;
    if (permille != null && (permille < 0 || permille > 1000)) {
      throw FormatException(
        'manualProgressPermille must be within 0..1000, got $permille.',
      );
    }
    if (progressMode == LearningProgressMode.manual &&
        manualProgressPermille == null) {
      throw const FormatException(
        'Manual progress mode requires a manual progress value.',
      );
    }
  }

  final LearningResourceId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final String title;
  final LearningResourceType type;
  final LearningResourceStatus status;
  final LearningProgressMode progressMode;

  /// The optional source URL (never fetched/scraped; stored for the user only).
  final String? sourceUri;
  final String? creator;

  /// A canonical note reference (R-NOTE-002); never an inline body.
  final String? noteId;

  /// The manual progress value in per-mille (0..1000) when [progressMode] is
  /// manual; null otherwise (R-LEARN-004).
  final int? manualProgressPermille;

  final String rank;
  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  LearningResource copyWith({
    String? title,
    LearningResourceType? type,
    LearningResourceStatus? status,
    LearningProgressMode? progressMode,
    Object? sourceUri = keepEdit,
    Object? creator = keepEdit,
    Object? noteId = keepEdit,
    Object? manualProgressPermille = keepEdit,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = keepEdit,
  }) {
    return LearningResource(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId,
      title: title ?? this.title,
      type: type ?? this.type,
      status: status ?? this.status,
      progressMode: progressMode ?? this.progressMode,
      sourceUri: identical(sourceUri, keepEdit)
          ? this.sourceUri
          : sourceUri as String?,
      creator: identical(creator, keepEdit) ? this.creator : creator as String?,
      noteId: identical(noteId, keepEdit) ? this.noteId : noteId as String?,
      manualProgressPermille: identical(manualProgressPermille, keepEdit)
          ? this.manualProgressPermille
          : manualProgressPermille as int?,
      rank: rank,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: identical(deletedAtUtc, keepEdit)
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }
}
