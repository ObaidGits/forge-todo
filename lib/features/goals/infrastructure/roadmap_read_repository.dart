import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_progress.dart';
import 'package:forge/features/goals/domain/roadmap_repository.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/infrastructure/roadmap_mapper.dart';

/// Drift-backed read model for roadmaps, sections, topics, and checklist items
/// (R-GOAL-003, R-GOAL-004). Reads run against the active local generation,
/// which is the client source of truth (design.md §8). Results come back in
/// stable rank order with the ID as the tie-breaker (R-GOAL-005).
final class RoadmapReadRepository implements RoadmapRepository {
  RoadmapReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<Roadmap?> findByGoal(ProfileId profileId, GoalId goalId) async {
    final RoadmapRow? row =
        await (_db.select(_db.roadmaps)..where(
              (Roadmaps t) =>
                  t.profileId.equals(profileId.value) &
                  t.goalId.equals(goalId.value) &
                  t.deletedAtUtc.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.fromRow(row);
  }

  @override
  Future<Roadmap?> findById(ProfileId profileId, RoadmapId roadmapId) async {
    final RoadmapRow? row =
        await (_db.select(_db.roadmaps)..where(
              (Roadmaps t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(roadmapId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.fromRow(row);
  }

  @override
  Future<List<RoadmapSection>> sectionsOf(
    ProfileId profileId,
    RoadmapId roadmapId,
  ) async {
    final List<RoadmapSectionRow> rows =
        await (_db.select(_db.roadmapSections)
              ..where(
                (RoadmapSections t) =>
                    t.profileId.equals(profileId.value) &
                    t.roadmapId.equals(roadmapId.value) &
                    t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<RoadmapSections>>[
                (RoadmapSections t) => OrderingTerm.asc(t.rank),
                (RoadmapSections t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return rows
        .map((RoadmapSectionRow r) => RoadmapMapper.sectionFromRow(r))
        .toList(growable: false);
  }

  @override
  Future<List<RoadmapTopic>> topicsOfSection(
    ProfileId profileId,
    RoadmapSectionId sectionId,
  ) async {
    final List<RoadmapTopicRow> rows =
        await (_db.select(_db.roadmapTopics)
              ..where(
                (RoadmapTopics t) =>
                    t.profileId.equals(profileId.value) &
                    t.sectionId.equals(sectionId.value) &
                    t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<RoadmapTopics>>[
                (RoadmapTopics t) => OrderingTerm.asc(t.rank),
                (RoadmapTopics t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return rows
        .map((RoadmapTopicRow r) => RoadmapMapper.topicFromRow(r))
        .toList(growable: false);
  }

  @override
  Future<List<RoadmapTopic>> topicsOfRoadmap(
    ProfileId profileId,
    RoadmapId roadmapId,
  ) async {
    // Join topics to their sections so a single query gathers every live topic
    // under the roadmap in stable (section rank, topic rank) order.
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT t.* FROM roadmap_topics t '
          'JOIN roadmap_sections s '
          '  ON s.profile_id = t.profile_id AND s.id = t.section_id '
          'WHERE t.profile_id = ? AND s.roadmap_id = ? '
          '  AND t.deleted_at_utc IS NULL AND s.deleted_at_utc IS NULL '
          'ORDER BY s.rank ASC, s.id ASC, t.rank ASC, t.id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(roadmapId.value),
          ],
          readsFrom: <ResultSetImplementation<HasResultSet, dynamic>>{
            _db.roadmapTopics,
            _db.roadmapSections,
          },
        )
        .get();
    return rows
        .map(
          (QueryRow r) =>
              RoadmapMapper.topicFromRow(_db.roadmapTopics.map(r.data)),
        )
        .toList(growable: false);
  }

  @override
  Future<RoadmapTopic?> findTopic(
    ProfileId profileId,
    RoadmapTopicId topicId,
  ) async {
    final RoadmapTopicRow? row =
        await (_db.select(_db.roadmapTopics)..where(
              (RoadmapTopics t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(topicId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.topicFromRow(row);
  }

  @override
  Future<GoalId?> goalIdOfTopic(
    ProfileId profileId,
    RoadmapTopicId topicId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT r.goal_id AS goal_id FROM roadmap_topics t '
          'JOIN roadmap_sections s '
          '  ON s.profile_id = t.profile_id AND s.id = t.section_id '
          'JOIN roadmaps r '
          '  ON r.profile_id = s.profile_id AND r.id = s.roadmap_id '
          'WHERE t.profile_id = ? AND t.id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(topicId.value),
          ],
          readsFrom: <ResultSetImplementation<HasResultSet, dynamic>>{
            _db.roadmapTopics,
            _db.roadmapSections,
            _db.roadmaps,
          },
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return GoalId(rows.single.data['goal_id'] as String);
  }

  @override
  Future<List<ChecklistItem>> checklistItemsOf(
    ProfileId profileId,
    RoadmapTopicId topicId,
  ) async {
    final List<ChecklistItemRow> rows =
        await (_db.select(_db.checklistItems)
              ..where(
                (ChecklistItems t) =>
                    t.profileId.equals(profileId.value) &
                    t.roadmapTopicId.equals(topicId.value) &
                    t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<ChecklistItems>>[
                (ChecklistItems t) => OrderingTerm.asc(t.rank),
                (ChecklistItems t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return rows
        .map((ChecklistItemRow r) => RoadmapMapper.checklistFromRow(r))
        .toList(growable: false);
  }

  @override
  Future<GoalProgress> deriveGoalProgress(
    ProfileId profileId,
    GoalId goalId,
  ) async {
    final Roadmap? roadmap = await findByGoal(profileId, goalId);
    if (roadmap == null) {
      // No roadmap: no computable derived progress (R-GOAL-004).
      return RoadmapProgressPolicy.forRoadmap(const <RoadmapTopic>[]);
    }
    final List<RoadmapTopic> topics = await topicsOfRoadmap(
      profileId,
      roadmap.id,
    );
    return RoadmapProgressPolicy.forRoadmap(topics);
  }
}
