import 'package:forge/features/learning/domain/edit_sentinel.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';

/// An immutable ordered item inside a Learning Resource (R-LEARN-001).
///
/// Items form the resource's ordered structure: a `section` groups eligible
/// leaves via [parentId]; leaves count toward derived progress (R-LEARN-004).
/// An item is complete when [completedAtUtc] is set. Item ordering uses the
/// stable lexicographic [rank] with the id as tie-breaker.
final class LearningItem {
  LearningItem({
    required this.id,
    required this.profileId,
    required this.courseId,
    required this.title,
    required this.type,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.parentId,
    this.sourceUri,
    this.durationSec,
    this.completedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Learning item title must not be empty.');
    }
    final int? duration = durationSec;
    if (duration != null && duration < 0) {
      throw FormatException('durationSec must be nonnegative, got $duration.');
    }
  }

  final String id;
  final String profileId;

  /// The owning Learning Resource id (`courses` internal schema name).
  final String courseId;

  /// The optional parent section id; null for a top-level item.
  final String? parentId;

  final String title;
  final LearningItemType type;
  final String? sourceUri;

  /// Optional canonical duration in seconds (e.g. a video length).
  final int? durationSec;

  /// The completion instant, or null when the item is incomplete.
  final int? completedAtUtc;

  final String rank;
  final int createdAtUtc;
  final int updatedAtUtc;

  /// Whether this item counts toward derived progress (R-LEARN-004).
  bool get isEligible => type.eligibleLeaf;

  bool get isComplete => completedAtUtc != null;

  LearningItem copyWith({
    String? title,
    LearningItemType? type,
    Object? sourceUri = keepEdit,
    Object? durationSec = keepEdit,
    Object? completedAtUtc = keepEdit,
    String? rank,
    int? updatedAtUtc,
  }) {
    return LearningItem(
      id: id,
      profileId: profileId,
      courseId: courseId,
      parentId: parentId,
      title: title ?? this.title,
      type: type ?? this.type,
      sourceUri: identical(sourceUri, keepEdit)
          ? this.sourceUri
          : sourceUri as String?,
      durationSec: identical(durationSec, keepEdit)
          ? this.durationSec
          : durationSec as int?,
      completedAtUtc: identical(completedAtUtc, keepEdit)
          ? this.completedAtUtc
          : completedAtUtc as int?,
      rank: rank ?? this.rank,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    );
  }
}
