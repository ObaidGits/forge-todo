import 'package:forge/core/domain/id.dart';

/// A Today active-study recommendation surfaced from real learning data
/// (R-HOME-001, R-LEARN-003).
///
/// The recommendation names the Learning Resource the user should continue and,
/// when the resource still has an incomplete item, the resume point resolved by
/// [R-LEARN-003] without mutating it. It is a read-only projection: surfacing it
/// on Today never changes the resource, its items, or its study sessions.
final class StudyRecommendation {
  const StudyRecommendation({
    required this.resourceId,
    required this.resourceTitle,
    required this.reason,
    this.resumeItemId,
    this.resumeItemTitle,
  });

  /// The Learning Resource to resume (opaque id; opens `/learn/<id>`).
  final String resourceId;

  /// The resource's display title.
  final String resourceTitle;

  /// The eligible incomplete item to resume, or null when the recommendation is
  /// the resource itself (e.g. it has no items yet).
  final String? resumeItemId;

  /// The resume item's display title, when [resumeItemId] is set.
  final String? resumeItemTitle;

  /// Why this resource/item was chosen: `last_studied` (the most recent study
  /// session's item is still incomplete), `first_incomplete` (fallback to the
  /// first incomplete eligible item in order), or `in_progress` (no study
  /// history yet, chosen from an in-progress resource).
  final String reason;
}

/// The exported learning application contract that surfaces the active study
/// recommendation for Today (R-HOME-001, R-LEARN-003).
///
/// Home composes this contract only — never the learning feature's domain
/// repository or infrastructure (design.md §4). The implementation identifies
/// the last incomplete item without changing it automatically (R-LEARN-003).
abstract interface class LearningResumeContract {
  /// The single active study recommendation for [profileId], optionally scoped
  /// to [lifeAreaId], or null when there is nothing to resume (no resource has
  /// an incomplete eligible item). Read-only: no resource is mutated.
  Future<StudyRecommendation?> activeStudyRecommendation(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  });
}
