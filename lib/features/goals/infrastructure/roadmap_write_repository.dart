import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_link.dart';
import 'package:forge/features/goals/infrastructure/roadmap_mapper.dart';

/// Transaction-scoped write access to the roadmap tables (`roadmaps`,
/// `roadmap_sections`, `roadmap_topics`, `checklist_items`).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes.
final class RoadmapWriteRepository {
  RoadmapWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- roadmap ------------------------------------------------------------

  Future<Roadmap?> find(String profileId, String roadmapId) async {
    scope.ensureActive();
    final RoadmapRow? row =
        await (db.select(db.roadmaps)..where(
              (Roadmaps t) =>
                  t.profileId.equals(profileId) & t.id.equals(roadmapId),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.fromRow(row);
  }

  Future<Roadmap?> findByGoal(String profileId, String goalId) async {
    scope.ensureActive();
    final RoadmapRow? row =
        await (db.select(db.roadmaps)..where(
              (Roadmaps t) =>
                  t.profileId.equals(profileId) & t.goalId.equals(goalId),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.fromRow(row);
  }

  Future<void> insertRoadmap(Roadmap roadmap) async {
    scope.ensureActive();
    await db.into(db.roadmaps).insert(RoadmapMapper.toInsert(roadmap));
  }

  Future<void> updateRoadmap(Roadmap roadmap) async {
    scope.ensureActive();
    await (db.update(db.roadmaps)..where(
          (Roadmaps t) =>
              t.profileId.equals(roadmap.profileId.value) &
              t.id.equals(roadmap.id.value),
        ))
        .write(RoadmapMapper.toUpdate(roadmap));
  }

  /// True when a live (non-deleted) goal [goalId] exists under [profileId], so
  /// a roadmap's composite parent FK resolves to a live goal (R-GOAL-001).
  Future<bool> liveGoalExists(String profileId, String goalId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM goals WHERE profile_id = ? AND id = ? '
          'AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(goalId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  // ---- section ------------------------------------------------------------

  Future<RoadmapSection?> findSection(
    String profileId,
    String sectionId,
  ) async {
    scope.ensureActive();
    final RoadmapSectionRow? row =
        await (db.select(db.roadmapSections)..where(
              (RoadmapSections t) =>
                  t.profileId.equals(profileId) & t.id.equals(sectionId),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.sectionFromRow(row);
  }

  Future<void> insertSection(RoadmapSection section) async {
    scope.ensureActive();
    await db
        .into(db.roadmapSections)
        .insert(RoadmapMapper.sectionToInsert(section));
  }

  Future<void> updateSection(RoadmapSection section) async {
    scope.ensureActive();
    await (db.update(db.roadmapSections)..where(
          (RoadmapSections t) =>
              t.profileId.equals(section.profileId.value) &
              t.id.equals(section.id.value),
        ))
        .write(RoadmapMapper.sectionToUpdate(section));
  }

  /// The live sections of [roadmapId] ordered by rank, used to append and to
  /// rebalance (R-GOAL-005).
  Future<List<RoadmapSection>> sectionsOrdered(
    String profileId,
    String roadmapId,
  ) async {
    scope.ensureActive();
    final List<RoadmapSectionRow> rows =
        await (db.select(db.roadmapSections)
              ..where(
                (RoadmapSections t) =>
                    t.profileId.equals(profileId) &
                    t.roadmapId.equals(roadmapId) &
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

  Future<GoalRank?> lastSectionRank(String profileId, String roadmapId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM roadmap_sections WHERE profile_id = ? '
          'AND roadmap_id = ? AND deleted_at_utc IS NULL '
          'ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(roadmapId),
          ],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  // ---- topic --------------------------------------------------------------

  Future<RoadmapTopic?> findTopic(String profileId, String topicId) async {
    scope.ensureActive();
    final RoadmapTopicRow? row =
        await (db.select(db.roadmapTopics)..where(
              (RoadmapTopics t) =>
                  t.profileId.equals(profileId) & t.id.equals(topicId),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.topicFromRow(row);
  }

  Future<void> insertTopic(RoadmapTopic topic) async {
    scope.ensureActive();
    await db.into(db.roadmapTopics).insert(RoadmapMapper.topicToInsert(topic));
  }

  Future<void> updateTopic(RoadmapTopic topic) async {
    scope.ensureActive();
    await (db.update(db.roadmapTopics)..where(
          (RoadmapTopics t) =>
              t.profileId.equals(topic.profileId.value) &
              t.id.equals(topic.id.value),
        ))
        .write(RoadmapMapper.topicToUpdate(topic));
  }

  /// The live topics of [sectionId] ordered by rank, used to append and to
  /// rebalance (R-GOAL-005).
  Future<List<RoadmapTopic>> topicsOrdered(
    String profileId,
    String sectionId,
  ) async {
    scope.ensureActive();
    final List<RoadmapTopicRow> rows =
        await (db.select(db.roadmapTopics)
              ..where(
                (RoadmapTopics t) =>
                    t.profileId.equals(profileId) &
                    t.sectionId.equals(sectionId) &
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

  Future<GoalRank?> lastTopicRank(String profileId, String sectionId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM roadmap_topics WHERE profile_id = ? '
          'AND section_id = ? AND deleted_at_utc IS NULL '
          'ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(sectionId),
          ],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  /// The ids of every live topic under [profileId], for the search rebuild
  /// path.
  Future<List<String>> activeTopicIds(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM roadmap_topics WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY id ASC',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  // ---- checklist item -----------------------------------------------------

  Future<ChecklistItem?> findChecklistItem(
    String profileId,
    String itemId,
  ) async {
    scope.ensureActive();
    final ChecklistItemRow? row =
        await (db.select(db.checklistItems)..where(
              (ChecklistItems t) =>
                  t.profileId.equals(profileId) & t.id.equals(itemId),
            ))
            .getSingleOrNull();
    return row == null ? null : RoadmapMapper.checklistFromRow(row);
  }

  Future<void> insertChecklistItem(ChecklistItem item) async {
    scope.ensureActive();
    await db
        .into(db.checklistItems)
        .insert(RoadmapMapper.checklistToInsert(item));
  }

  Future<void> updateChecklistItem(ChecklistItem item) async {
    scope.ensureActive();
    await (db.update(db.checklistItems)..where(
          (ChecklistItems t) =>
              t.profileId.equals(item.profileId.value) &
              t.id.equals(item.id.value),
        ))
        .write(RoadmapMapper.checklistToUpdate(item));
  }

  Future<GoalRank?> lastChecklistRank(String profileId, String topicId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM checklist_items WHERE profile_id = ? '
          'AND roadmap_topic_id = ? AND deleted_at_utc IS NULL '
          'ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(topicId),
          ],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  /// True when a live (non-deleted) note [noteId] exists under [profileId],
  /// used to reject a canonical-note reference that does not resolve locally
  /// (R-GEN-002). Returns false when the notes table is absent.
  Future<bool> liveNoteExists(String profileId, String noteId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM notes WHERE profile_id = ? AND id = ? '
          'AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(noteId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }

  // ---- topic links (entity_links) -----------------------------------------

  /// Recognized topic link target type → owner table carrying `(profile_id,
  /// id)`. Only types whose owning feature is present appear here; the internal
  /// `courses` table backs the user-facing Learning Resource.
  static const Map<String, String> topicLinkTargetTables = <String, String>{
    RoadmapTopicTargetType.task: 'tasks',
    RoadmapTopicTargetType.note: 'notes',
    RoadmapTopicTargetType.learningResource: 'courses',
  };

  Future<bool> liveTopicExists(String profileId, String topicId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM roadmap_topics WHERE profile_id = ? AND id = ? '
          'AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(topicId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<GoalRank?> lastLinkRank(String profileId, String topicId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM entity_links WHERE profile_id = ? '
          'AND from_type = ? AND from_id = ? AND relation = ? '
          'ORDER BY rank DESC, to_id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            const Variable<String>(roadmapTopicFromType),
            Variable<String>(topicId),
            const Variable<String>(roadmapTopicLinkRelation),
          ],
        )
        .get();
    return rows.isEmpty ? null : GoalRank(rows.single.data['rank'] as String);
  }

  /// Links topic [topicId] to `(targetType, targetId)` through `entity_links`,
  /// validating the topic is live and the profile-scoped target exists
  /// (R-GOAL-003, R-GEN-002). Idempotent on the unique link tuple.
  Future<RoadmapTopicLinkOutcome> linkEntity({
    required String id,
    required String profileId,
    required String topicId,
    required String targetType,
    required String targetId,
    required String rank,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    if (!RoadmapTopicTargetType.all.contains(targetType)) {
      return RoadmapTopicLinkOutcome.targetTypeUnknown;
    }
    if (!await liveTopicExists(profileId, topicId)) {
      return RoadmapTopicLinkOutcome.topicMissing;
    }
    final String? table = topicLinkTargetTables[targetType];
    if (table == null) {
      return RoadmapTopicLinkOutcome.targetTypeUnavailable;
    }
    if (!await _targetExists(table, profileId, targetId)) {
      // Not found under this profile — includes another profile's id
      // (cross-profile rejection, R-GEN-002).
      return RoadmapTopicLinkOutcome.targetMissing;
    }
    final int inserted = await db.customUpdate(
      'INSERT OR IGNORE INTO entity_links '
      '(id, profile_id, from_type, from_id, relation, to_type, to_id, rank, '
      'created_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: <Variable<Object>>[
        Variable<String>(id),
        Variable<String>(profileId),
        const Variable<String>(roadmapTopicFromType),
        Variable<String>(topicId),
        const Variable<String>(roadmapTopicLinkRelation),
        Variable<String>(targetType),
        Variable<String>(targetId),
        Variable<String>(rank),
        Variable<int>(nowUtc),
      ],
      updateKind: UpdateKind.insert,
    );
    return inserted == 0
        ? RoadmapTopicLinkOutcome.alreadyLinked
        : RoadmapTopicLinkOutcome.linked;
  }

  /// Removes the topic link tuple if present. Returns rows deleted (0 keeps
  /// unlink idempotent).
  Future<int> unlinkEntity({
    required String profileId,
    required String topicId,
    required String targetType,
    required String targetId,
  }) async {
    scope.ensureActive();
    return db.customUpdate(
      'DELETE FROM entity_links WHERE profile_id = ? AND from_type = ? '
      'AND from_id = ? AND relation = ? AND to_type = ? AND to_id = ?',
      variables: <Variable<Object>>[
        Variable<String>(profileId),
        const Variable<String>(roadmapTopicFromType),
        Variable<String>(topicId),
        const Variable<String>(roadmapTopicLinkRelation),
        Variable<String>(targetType),
        Variable<String>(targetId),
      ],
      updateKind: UpdateKind.delete,
    );
  }

  Future<bool> _targetExists(
    String table,
    String profileId,
    String targetId,
  ) async {
    // [table] comes only from the controlled [topicLinkTargetTables] registry;
    // it is never user input, so interpolating the identifier is safe.
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM $table WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(targetId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }
}
