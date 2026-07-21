import 'package:forge/core/domain/id.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/learning_statistics.dart';
import 'package:forge/features/learning/domain/study_session.dart';

/// Read access to learning aggregates. Query methods run outside a write
/// transaction and return immutable domain aggregates (design.md §5 "Queries").
abstract interface class LearningRepository {
  /// The non-deleted Learning Resources of a profile, most recently updated
  /// first (R-LEARN-001). Used by the Learn list surface.
  Future<List<LearningResource>> listResources(ProfileId profileId);

  /// The resource with [resourceId], or null when absent/soft-deleted.
  Future<LearningResource?> findResource(
    ProfileId profileId,
    LearningResourceId resourceId,
  );

  /// The resource's items ordered by ascending rank then id (R-LEARN-001).
  Future<List<LearningItem>> itemsOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  );

  /// The current (non-superseded) study sessions of a resource, most recent
  /// first (R-LEARN-002).
  Future<List<StudySession>> currentSessionsOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  );

  /// The append-only lifecycle events of a logical study session, oldest first.
  Future<List<StudySessionEvent>> sessionEvents(
    ProfileId profileId,
    String logicalId,
  );

  /// The derived (or manual) progress of a resource (R-LEARN-004).
  Future<LearningProgress> progressOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  );

  /// The resume point of a resource without mutating it (R-LEARN-003).
  Future<ResumePoint> resumePoint(
    ProfileId profileId,
    LearningResourceId resourceId,
  );

  /// Studied-duration/completed-items statistics over a transparent range,
  /// optionally filtered by area and/or resource (R-LEARN-005).
  Future<LearningStatistics> statistics(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  });
}
