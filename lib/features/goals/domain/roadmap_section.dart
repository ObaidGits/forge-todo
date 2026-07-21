import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';

/// An immutable roadmap section aggregate (R-GOAL-003, R-GOAL-004).
///
/// A section is a strictly-owned inherited-area child of a roadmap: it
/// references the roadmap through the composite `(profile_id, roadmap_id)`
/// parent key (data-model §1). Sections are ordered by a stable fractional
/// [rank] (R-GOAL-005).
///
/// A section has **no completion weight** in V1 (R-GOAL-004): it never
/// contributes to derived progress on its own. Any per-section progress shown
/// in the UI is a presentation-only aggregation of its eligible descendant
/// topic weights, computed on the fly and never persisted.
final class RoadmapSection {
  RoadmapSection({
    required this.id,
    required this.profileId,
    required this.roadmapId,
    required this.title,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Roadmap section title must not be empty.');
    }
  }

  final RoadmapSectionId id;
  final ProfileId profileId;
  final RoadmapId roadmapId;
  final String title;

  /// Stable manual ordering rank within the roadmap (R-GOAL-005).
  final GoalRank rank;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  RoadmapSection copyWith({
    String? title,
    GoalRank? rank,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return RoadmapSection(
      id: id,
      profileId: profileId,
      roadmapId: roadmapId,
      title: title ?? this.title,
      rank: rank ?? this.rank,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  /// Passed to [copyWith] for a clearable field to mean "leave unchanged".
  static const Object unchanged = _sentinel;

  static const Object _sentinel = Object();
}
