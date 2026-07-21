import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart'
    show MoveInput;
import 'package:forge/features/goals/application/roadmap_command_service.dart';
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_link.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/goals/infrastructure/goal_canonical_request.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exceptions raised inside a command body; they roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.entityId);
  final String entityId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed [RoadmapCommandService] (R-GOAL-003, R-GOAL-004,
/// R-GOAL-005, R-GEN-005).
///
/// Every mutation is one atomic transaction that writes the roadmap row(s),
/// marks the unified search projection dirty for topic title changes
/// (maintained in-commit by the registered [RoadmapTopicSearchProjector]), and
/// appends activity — all alongside the cross-cutting
/// receipt/activity/outbox/journal write set. Rank rebalancing emits one
/// semantic group patching every reordered row, so it converges deterministically
/// under sync (R-GOAL-005; data-model §6 conflict rule 6).
final class DriftRoadmapCommandService implements RoadmapCommandService {
  DriftRoadmapCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;
  static const String _roadmapEntity = 'roadmap';
  static const String _sectionEntity = 'roadmap_section';
  static const String _checklistEntity = 'checklist_item';
  static const String _topicLinkEntity = 'roadmap_topic_link';

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  // ---- roadmap commands ---------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> createRoadmap({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required CreateRoadmapInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create_roadmap',
      'goal_id': goalId.value,
      'title': input.title,
      'status': input.status.wire,
      'target_date': input.targetDate,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createRoadmapBody(session, profileId, goalId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> updateRoadmap({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
    required UpdateRoadmapInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_roadmap',
      'roadmap_id': roadmapId.value,
      if (input.title != null) 'title': input.title,
      if (input.status != null) 'status': input.status!.wire,
      if (input.targetDate != null) 'target_date': input.targetDate!.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateRoadmapBody(session, profileId, roadmapId, input),
    );
  }

  // ---- section commands ---------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
    required CreateSectionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_section',
      'roadmap_id': roadmapId.value,
      'title': input.title,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.add_section',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addSectionBody(session, profileId, roadmapId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> updateSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required UpdateSectionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_section',
      'section_id': sectionId.value,
      if (input.title != null) 'title': input.title,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.update_section',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateSectionBody(session, profileId, sectionId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> moveSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required MoveInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move_section',
      'section_id': sectionId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.move_section',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveSectionBody(session, profileId, sectionId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> rebalanceSections({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'rebalance_sections',
      'roadmap_id': roadmapId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.rebalance_sections',
      canonical: canonical,
      body: (TransactionSession session) =>
          _rebalanceSectionsBody(session, profileId, roadmapId),
    );
  }

  // ---- topic commands -----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required CreateTopicInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_topic',
      'section_id': sectionId.value,
      'title': input.title,
      'status': input.status.wire,
      'weight': input.weight,
      'estimate_sec': input.estimateSec,
      'note_id': input.noteId?.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.add_topic',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addTopicBody(session, profileId, sectionId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> updateTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required UpdateTopicInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_topic',
      'topic_id': topicId.value,
      if (input.title != null) 'title': input.title,
      if (input.weight != null) 'weight': input.weight!.value,
      if (input.estimateSec != null) 'estimate_sec': input.estimateSec!.value,
      if (input.noteId != null) 'note_id': input.noteId!.value?.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.update_topic',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateTopicBody(session, profileId, topicId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setTopicStatus({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required RoadmapTopicStatus status,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_topic_status',
      'topic_id': topicId.value,
      'status': status.wire,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.set_topic_status',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setTopicStatusBody(session, profileId, topicId, status),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> moveTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required MoveInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move_topic',
      'topic_id': topicId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.move_topic',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveTopicBody(session, profileId, topicId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> rebalanceTopics({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'rebalance_topics',
      'section_id': sectionId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.rebalance_topics',
      canonical: canonical,
      body: (TransactionSession session) =>
          _rebalanceTopicsBody(session, profileId, sectionId),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> linkTopicEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required LinkTopicEntityInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'link_topic_entity',
      'topic_id': topicId.value,
      'target_type': input.targetType,
      'target_id': input.targetId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.link_topic_entity',
      canonical: canonical,
      body: (TransactionSession session) =>
          _linkTopicEntityBody(session, profileId, topicId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> unlinkTopicEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required LinkTopicEntityInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'unlink_topic_entity',
      'topic_id': topicId.value,
      'target_type': input.targetType,
      'target_id': input.targetId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.unlink_topic_entity',
      canonical: canonical,
      body: (TransactionSession session) =>
          _unlinkTopicEntityBody(session, profileId, topicId, input),
    );
  }

  // ---- checklist commands -------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required CreateChecklistItemInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_checklist_item',
      'topic_id': topicId.value,
      'text': input.text,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.add_checklist_item',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addChecklistItemBody(session, profileId, topicId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> updateChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required UpdateChecklistItemInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_checklist_item',
      'item_id': itemId.value,
      if (input.text != null) 'text': input.text,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.update_checklist_item',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateChecklistItemBody(session, profileId, itemId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setChecklistItemChecked({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required bool checked,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_checklist_checked',
      'item_id': itemId.value,
      'checked': checked,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.set_checklist_checked',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setChecklistCheckedBody(session, profileId, itemId, checked),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> moveChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required MoveInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move_checklist_item',
      'item_id': itemId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'roadmap.move_checklist_item',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveChecklistItemBody(session, profileId, itemId, input),
    );
  }

  // ---- roadmap bodies -----------------------------------------------------

  Future<SemanticWrite> _createRoadmapBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    CreateRoadmapInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    if (!await repo.liveGoalExists(profileId.value, goalId.value)) {
      throw _NotFound(goalId.value);
    }
    // A goal owns at most one roadmap (R-GOAL-001); reject a second one.
    final Roadmap? existing = await repo.findByGoal(
      profileId.value,
      goalId.value,
    );
    if (existing != null && !existing.isDeleted) {
      throw const _Validation('roadmap.already_exists');
    }
    final int now = _now;
    final String roadmapId = idGenerator.uuidV7();
    final Roadmap roadmap = _guard(
      () => Roadmap(
        id: RoadmapId(roadmapId),
        profileId: profileId,
        goalId: goalId,
        title: input.title,
        status: input.status,
        targetDate: input.targetDate,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      'roadmap.invalid_field',
    );
    await repo.insertRoadmap(roadmap);
    return _write(
      repo,
      profileId,
      resultCode: 'roadmap_created',
      resultPayload: '{"id":"$roadmapId","goal_id":"${goalId.value}"}',
      activity: <ActivityDraft>[
        _activity('roadmap_created', _roadmapEntity, roadmapId),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _roadmapEntity,
          entityId: roadmapId,
          opKind: 'insert',
          payload: _roadmapPayload(roadmap),
        ),
      ],
    );
  }

  Future<SemanticWrite> _updateRoadmapBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapId roadmapId,
    UpdateRoadmapInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final Roadmap current = await _loadRoadmap(repo, profileId, roadmapId);
    if (input.isEmpty) {
      return _noop(roadmapId.value);
    }
    final int now = _now;
    final Roadmap updated = _guard(
      () => current.copyWith(
        title: input.title,
        status: input.status,
        targetDate: input.targetDate == null
            ? Roadmap.unchanged
            : input.targetDate!.value,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
      'roadmap.invalid_field',
    );
    await repo.updateRoadmap(updated);
    return _write(
      repo,
      profileId,
      resultCode: 'roadmap_updated',
      resultPayload: '{"id":"${roadmapId.value}"}',
      activity: <ActivityDraft>[
        _activity('roadmap_updated', _roadmapEntity, roadmapId.value),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _roadmapEntity,
          entityId: roadmapId.value,
          opKind: 'patch',
          baseRowVersion: current.revision,
          payload: _roadmapPayload(updated),
        ),
      ],
    );
  }

  // ---- section bodies -----------------------------------------------------

  Future<SemanticWrite> _addSectionBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapId roadmapId,
    CreateSectionInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    await _loadRoadmap(repo, profileId, roadmapId);
    final int now = _now;
    final GoalRank rank = GoalRank.append(
      await repo.lastSectionRank(profileId.value, roadmapId.value),
    );
    final String sectionId = idGenerator.uuidV7();
    final RoadmapSection section = _guard(
      () => RoadmapSection(
        id: RoadmapSectionId(sectionId),
        profileId: profileId,
        roadmapId: roadmapId,
        title: input.title,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      'roadmap.section_invalid_field',
    );
    await repo.insertSection(section);
    return _write(
      repo,
      profileId,
      resultCode: 'section_created',
      resultPayload: '{"id":"$sectionId","roadmap_id":"${roadmapId.value}"}',
      activity: <ActivityDraft>[
        _activity('section_created', _sectionEntity, sectionId),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _sectionEntity,
          entityId: sectionId,
          opKind: 'insert',
          payload: _sectionPayload(section),
        ),
      ],
    );
  }

  Future<SemanticWrite> _updateSectionBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapSectionId sectionId,
    UpdateSectionInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final RoadmapSection current = await _loadSection(
      repo,
      profileId,
      sectionId,
    );
    if (input.isEmpty) {
      return _noop(sectionId.value);
    }
    final int now = _now;
    final RoadmapSection updated = _guard(
      () => current.copyWith(
        title: input.title,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
      'roadmap.section_invalid_field',
    );
    await repo.updateSection(updated);
    return _sectionPatch(
      repo,
      profileId,
      updated,
      current.revision,
      'section_updated',
      'title',
    );
  }

  Future<SemanticWrite> _moveSectionBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapSectionId sectionId,
    MoveInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final RoadmapSection current = await _loadSection(
      repo,
      profileId,
      sectionId,
    );
    if (input.beforeRank == null && input.afterRank == null) {
      return _noop(sectionId.value);
    }
    final GoalRank rank = _guardRank(
      () => GoalRank.between(
        input.beforeRank == null ? null : GoalRank.parse(input.beforeRank!),
        input.afterRank == null ? null : GoalRank.parse(input.afterRank!),
      ),
    );
    final RoadmapSection moved = current.copyWith(
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: _now,
    );
    await repo.updateSection(moved);
    return _sectionPatch(
      repo,
      profileId,
      moved,
      current.revision,
      'section_moved',
      'rank',
      resultPayload: '{"id":"${sectionId.value}","rank":"${rank.value}"}',
    );
  }

  Future<SemanticWrite> _rebalanceSectionsBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapId roadmapId,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    await _loadRoadmap(repo, profileId, roadmapId);
    final List<RoadmapSection> ordered = await repo.sectionsOrdered(
      profileId.value,
      roadmapId.value,
    );
    if (ordered.isEmpty) {
      return _noop(roadmapId.value);
    }
    final int now = _now;
    final List<GoalRank> fresh = GoalRank.distribute(ordered.length);
    final List<ActivityDraft> activity = <ActivityDraft>[];
    final List<OutboxOperationDraft> ops = <OutboxOperationDraft>[];
    for (int i = 0; i < ordered.length; i += 1) {
      final RoadmapSection updated = ordered[i].copyWith(
        rank: fresh[i],
        revision: ordered[i].revision + 1,
        updatedAtUtc: now,
      );
      await repo.updateSection(updated);
      ops.add(
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _sectionEntity,
          entityId: updated.id.value,
          opKind: 'patch',
          changedFields: 'rank',
          baseRowVersion: ordered[i].revision,
          payload: _sectionPayload(updated),
        ),
      );
    }
    activity.add(
      _activity('sections_rebalanced', _roadmapEntity, roadmapId.value),
    );
    return _write(
      repo,
      profileId,
      resultCode: 'sections_rebalanced',
      resultPayload:
          '{"roadmap_id":"${roadmapId.value}","count":${ordered.length}}',
      activity: activity,
      operations: ops,
    );
  }

  // ---- topic bodies -------------------------------------------------------

  Future<SemanticWrite> _addTopicBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapSectionId sectionId,
    CreateTopicInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    await _loadSection(repo, profileId, sectionId);
    await _ensureNoteResolves(repo, profileId, input.noteId);
    final int now = _now;
    final GoalRank rank = GoalRank.append(
      await repo.lastTopicRank(profileId.value, sectionId.value),
    );
    final String topicId = idGenerator.uuidV7();
    final RoadmapTopic topic = _guard(
      () => RoadmapTopic(
        id: RoadmapTopicId(topicId),
        profileId: profileId,
        sectionId: sectionId,
        title: input.title,
        status: input.status,
        weight: input.weight,
        estimateSec: input.estimateSec,
        noteId: input.noteId,
        completedAtUtc: input.status.isCompleted ? now : null,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      'roadmap.topic_invalid_field',
    );
    await repo.insertTopic(topic);
    return _write(
      repo,
      profileId,
      resultCode: 'topic_created',
      resultPayload: '{"id":"$topicId","section_id":"${sectionId.value}"}',
      activity: <ActivityDraft>[
        _activity('topic_created', RoadmapTopicSearchProjector.kind, topicId),
      ],
      dirtyProjections: _topicDirty(topicId),
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: RoadmapTopicSearchProjector.kind,
          entityId: topicId,
          opKind: 'insert',
          payload: _topicPayload(topic),
        ),
      ],
    );
  }

  Future<SemanticWrite> _updateTopicBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    UpdateTopicInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final RoadmapTopic current = await _loadTopic(repo, profileId, topicId);
    if (input.isEmpty) {
      return _noop(topicId.value);
    }
    if (input.noteId != null) {
      await _ensureNoteResolves(repo, profileId, input.noteId!.value);
    }
    final int now = _now;
    final RoadmapTopic updated = _guard(
      () => current.copyWith(
        title: input.title,
        weight: input.weight == null
            ? RoadmapTopic.unchanged
            : input.weight!.value,
        estimateSec: input.estimateSec == null
            ? RoadmapTopic.unchanged
            : input.estimateSec!.value,
        noteId: input.noteId == null
            ? RoadmapTopic.unchanged
            : input.noteId!.value,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
      'roadmap.topic_invalid_field',
    );
    await repo.updateTopic(updated);
    // Only a title change affects the topic's searchable content.
    final bool searchable = input.title != null;
    return _topicPatch(
      repo,
      profileId,
      updated,
      current.revision,
      'topic_updated',
      'title,weight,estimate_sec,note_id',
      searchDirty: searchable,
    );
  }

  Future<SemanticWrite> _setTopicStatusBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    RoadmapTopicStatus status,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final RoadmapTopic current = await _loadTopic(repo, profileId, topicId);
    if (current.status == status) {
      return _noop(topicId.value);
    }
    final int now = _now;
    // Set the completion instant when transitioning into completed; clear it
    // otherwise so an uncompleted topic contributes only its eligibility to
    // derived progress (R-GOAL-004).
    final RoadmapTopic updated = current.copyWith(
      status: status,
      completedAtUtc: status.isCompleted
          ? (current.completedAtUtc ?? now)
          : null,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateTopic(updated);
    return _topicPatch(
      repo,
      profileId,
      updated,
      current.revision,
      'topic_status_changed',
      'status,completed_at_utc',
      resultCode: 'topic_status_changed',
    );
  }

  Future<SemanticWrite> _moveTopicBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    MoveInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final RoadmapTopic current = await _loadTopic(repo, profileId, topicId);
    if (input.beforeRank == null && input.afterRank == null) {
      return _noop(topicId.value);
    }
    final GoalRank rank = _guardRank(
      () => GoalRank.between(
        input.beforeRank == null ? null : GoalRank.parse(input.beforeRank!),
        input.afterRank == null ? null : GoalRank.parse(input.afterRank!),
      ),
    );
    final RoadmapTopic moved = current.copyWith(
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: _now,
    );
    await repo.updateTopic(moved);
    return _topicPatch(
      repo,
      profileId,
      moved,
      current.revision,
      'topic_moved',
      'rank',
      resultCode: 'topic_moved',
      resultPayload: '{"id":"${topicId.value}","rank":"${rank.value}"}',
      searchDirty: false,
    );
  }

  Future<SemanticWrite> _rebalanceTopicsBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapSectionId sectionId,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    await _loadSection(repo, profileId, sectionId);
    final List<RoadmapTopic> ordered = await repo.topicsOrdered(
      profileId.value,
      sectionId.value,
    );
    if (ordered.isEmpty) {
      return _noop(sectionId.value);
    }
    final int now = _now;
    final List<GoalRank> fresh = GoalRank.distribute(ordered.length);
    final List<OutboxOperationDraft> ops = <OutboxOperationDraft>[];
    for (int i = 0; i < ordered.length; i += 1) {
      final RoadmapTopic updated = ordered[i].copyWith(
        rank: fresh[i],
        revision: ordered[i].revision + 1,
        updatedAtUtc: now,
      );
      await repo.updateTopic(updated);
      ops.add(
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: RoadmapTopicSearchProjector.kind,
          entityId: updated.id.value,
          opKind: 'patch',
          changedFields: 'rank',
          baseRowVersion: ordered[i].revision,
          payload: _topicPayload(updated),
        ),
      );
    }
    return _write(
      repo,
      profileId,
      resultCode: 'topics_rebalanced',
      resultPayload:
          '{"section_id":"${sectionId.value}","count":${ordered.length}}',
      activity: <ActivityDraft>[
        _activity('topics_rebalanced', _sectionEntity, sectionId.value),
      ],
      operations: ops,
    );
  }

  Future<SemanticWrite> _linkTopicEntityBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    LinkTopicEntityInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final int now = _now;
    final String linkId = idGenerator.uuidV7();
    final GoalRank rank = GoalRank.append(
      await repo.lastLinkRank(profileId.value, topicId.value),
    );
    final RoadmapTopicLinkOutcome outcome = await repo.linkEntity(
      id: linkId,
      profileId: profileId.value,
      topicId: topicId.value,
      targetType: input.targetType,
      targetId: input.targetId,
      rank: rank.value,
      nowUtc: now,
    );
    switch (outcome) {
      case RoadmapTopicLinkOutcome.topicMissing:
        throw _NotFound(topicId.value);
      case RoadmapTopicLinkOutcome.targetTypeUnknown:
        throw const _Validation('roadmap.link_target_type_unknown');
      case RoadmapTopicLinkOutcome.targetTypeUnavailable:
        throw const _Validation('roadmap.link_target_type_unavailable');
      case RoadmapTopicLinkOutcome.targetMissing:
        throw const _Validation('roadmap.link_target_not_found');
      case RoadmapTopicLinkOutcome.alreadyLinked:
        return _noop(topicId.value);
      case RoadmapTopicLinkOutcome.linked:
        break;
    }
    return _write(
      repo,
      profileId,
      resultCode: 'topic_linked',
      resultPayload: '{"id":"$linkId","topic_id":"${topicId.value}"}',
      activity: <ActivityDraft>[
        _activity('topic_linked', _topicLinkEntity, linkId),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _topicLinkEntity,
          entityId: linkId,
          opKind: 'insert',
          payload: _linkPayload(
            linkId,
            topicId.value,
            input.targetType,
            input.targetId,
            rank.value,
          ),
        ),
      ],
    );
  }

  Future<SemanticWrite> _unlinkTopicEntityBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    LinkTopicEntityInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final int removed = await repo.unlinkEntity(
      profileId: profileId.value,
      topicId: topicId.value,
      targetType: input.targetType,
      targetId: input.targetId,
    );
    if (removed == 0) {
      return _noop(topicId.value);
    }
    return _write(
      repo,
      profileId,
      resultCode: 'topic_unlinked',
      resultPayload: '{"topic_id":"${topicId.value}"}',
      activity: <ActivityDraft>[
        _activity('topic_unlinked', _topicLinkEntity, topicId.value),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _topicLinkEntity,
          entityId: '${topicId.value}:${input.targetType}:${input.targetId}',
          opKind: 'delete',
          payload: _linkPayload(
            null,
            topicId.value,
            input.targetType,
            input.targetId,
            null,
          ),
        ),
      ],
    );
  }

  // ---- checklist bodies ---------------------------------------------------

  Future<SemanticWrite> _addChecklistItemBody(
    TransactionSession session,
    ProfileId profileId,
    RoadmapTopicId topicId,
    CreateChecklistItemInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    await _loadTopic(repo, profileId, topicId);
    final int now = _now;
    final GoalRank rank = GoalRank.append(
      await repo.lastChecklistRank(profileId.value, topicId.value),
    );
    final String itemId = idGenerator.uuidV7();
    final ChecklistItem item = _guard(
      () => ChecklistItem(
        id: ChecklistItemId(itemId),
        profileId: profileId,
        roadmapTopicId: topicId,
        text: input.text,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      'roadmap.checklist_invalid_field',
    );
    await repo.insertChecklistItem(item);
    return _write(
      repo,
      profileId,
      resultCode: 'checklist_item_created',
      resultPayload: '{"id":"$itemId","topic_id":"${topicId.value}"}',
      activity: <ActivityDraft>[
        _activity('checklist_item_created', _checklistEntity, itemId),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _checklistEntity,
          entityId: itemId,
          opKind: 'insert',
          payload: _checklistPayload(item),
        ),
      ],
    );
  }

  Future<SemanticWrite> _updateChecklistItemBody(
    TransactionSession session,
    ProfileId profileId,
    ChecklistItemId itemId,
    UpdateChecklistItemInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final ChecklistItem current = await _loadChecklistItem(
      repo,
      profileId,
      itemId,
    );
    if (input.isEmpty) {
      return _noop(itemId.value);
    }
    final ChecklistItem updated = _guard(
      () => current.copyWith(
        text: input.text,
        revision: current.revision + 1,
        updatedAtUtc: _now,
      ),
      'roadmap.checklist_invalid_field',
    );
    await repo.updateChecklistItem(updated);
    return _checklistPatch(
      repo,
      profileId,
      updated,
      current.revision,
      'checklist_item_updated',
      'text',
    );
  }

  Future<SemanticWrite> _setChecklistCheckedBody(
    TransactionSession session,
    ProfileId profileId,
    ChecklistItemId itemId,
    bool checked,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final ChecklistItem current = await _loadChecklistItem(
      repo,
      profileId,
      itemId,
    );
    if (current.isChecked == checked) {
      return _noop(itemId.value);
    }
    final int now = _now;
    final ChecklistItem updated = current.copyWith(
      checkedAtUtc: checked ? now : null,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateChecklistItem(updated);
    return _checklistPatch(
      repo,
      profileId,
      updated,
      current.revision,
      checked ? 'checklist_item_checked' : 'checklist_item_unchecked',
      'checked_at_utc',
      resultCode: checked
          ? 'checklist_item_checked'
          : 'checklist_item_unchecked',
    );
  }

  Future<SemanticWrite> _moveChecklistItemBody(
    TransactionSession session,
    ProfileId profileId,
    ChecklistItemId itemId,
    MoveInput input,
  ) async {
    final RoadmapWriteRepository repo = _repo(session);
    final ChecklistItem current = await _loadChecklistItem(
      repo,
      profileId,
      itemId,
    );
    if (input.beforeRank == null && input.afterRank == null) {
      return _noop(itemId.value);
    }
    final GoalRank rank = _guardRank(
      () => GoalRank.between(
        input.beforeRank == null ? null : GoalRank.parse(input.beforeRank!),
        input.afterRank == null ? null : GoalRank.parse(input.afterRank!),
      ),
    );
    final ChecklistItem moved = current.copyWith(
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: _now,
    );
    await repo.updateChecklistItem(moved);
    return _checklistPatch(
      repo,
      profileId,
      moved,
      current.revision,
      'checklist_item_moved',
      'rank',
      resultCode: 'checklist_item_moved',
      resultPayload: '{"id":"${itemId.value}","rank":"${rank.value}"}',
    );
  }

  // ---- shared write helpers -----------------------------------------------

  RoadmapWriteRepository _repo(TransactionSession session) =>
      session.repositories.resolve<RoadmapWriteRepository>();

  Future<SemanticWrite> _sectionPatch(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    RoadmapSection section,
    int baseRevision,
    String eventType,
    String changedFields, {
    String? resultCode,
    String? resultPayload,
  }) async {
    return _write(
      repo,
      profileId,
      resultCode: resultCode ?? eventType,
      resultPayload: resultPayload ?? '{"id":"${section.id.value}"}',
      activity: <ActivityDraft>[
        _activity(eventType, _sectionEntity, section.id.value),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _sectionEntity,
          entityId: section.id.value,
          opKind: 'patch',
          changedFields: changedFields,
          baseRowVersion: baseRevision,
          payload: _sectionPayload(section),
        ),
      ],
    );
  }

  Future<SemanticWrite> _topicPatch(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    RoadmapTopic topic,
    int baseRevision,
    String eventType,
    String changedFields, {
    String? resultCode,
    String? resultPayload,
    bool searchDirty = true,
  }) async {
    return _write(
      repo,
      profileId,
      resultCode: resultCode ?? eventType,
      resultPayload: resultPayload ?? '{"id":"${topic.id.value}"}',
      activity: <ActivityDraft>[
        _activity(eventType, RoadmapTopicSearchProjector.kind, topic.id.value),
      ],
      dirtyProjections: searchDirty
          ? _topicDirty(topic.id.value)
          : const <DirtyProjectionDraft>[],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: RoadmapTopicSearchProjector.kind,
          entityId: topic.id.value,
          opKind: 'patch',
          changedFields: changedFields,
          baseRowVersion: baseRevision,
          payload: _topicPayload(topic),
        ),
      ],
    );
  }

  Future<SemanticWrite> _checklistPatch(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    ChecklistItem item,
    int baseRevision,
    String eventType,
    String changedFields, {
    String? resultCode,
    String? resultPayload,
  }) async {
    return _write(
      repo,
      profileId,
      resultCode: resultCode ?? eventType,
      resultPayload: resultPayload ?? '{"id":"${item.id.value}"}',
      activity: <ActivityDraft>[
        _activity(eventType, _checklistEntity, item.id.value),
      ],
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _checklistEntity,
          entityId: item.id.value,
          opKind: 'patch',
          changedFields: changedFields,
          baseRowVersion: baseRevision,
          payload: _checklistPayload(item),
        ),
      ],
    );
  }

  Future<SemanticWrite> _write(
    RoadmapWriteRepository repo,
    ProfileId profileId, {
    required String resultCode,
    required String resultPayload,
    required List<ActivityDraft> activity,
    required List<OutboxOperationDraft> operations,
    List<DirtyProjectionDraft> dirtyProjections =
        const <DirtyProjectionDraft>[],
  }) async {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: activity,
      dirtyProjections: dirtyProjections,
      outboxGroup: operations.isEmpty
          ? null
          : OutboxGroupDraft(
              groupId: idGenerator.uuidV7(),
              snapshotEpoch: await repo.currentEpoch(profileId.value),
              operations: operations,
            ),
    );
  }

  // ---- loaders ------------------------------------------------------------

  Future<Roadmap> _loadRoadmap(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    RoadmapId roadmapId,
  ) async {
    final Roadmap? current = await repo.find(profileId.value, roadmapId.value);
    if (current == null) {
      throw _NotFound(roadmapId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('roadmap.deleted');
    }
    return current;
  }

  Future<RoadmapSection> _loadSection(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    RoadmapSectionId sectionId,
  ) async {
    final RoadmapSection? current = await repo.findSection(
      profileId.value,
      sectionId.value,
    );
    if (current == null) {
      throw _NotFound(sectionId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('roadmap.section_deleted');
    }
    return current;
  }

  Future<RoadmapTopic> _loadTopic(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    RoadmapTopicId topicId,
  ) async {
    final RoadmapTopic? current = await repo.findTopic(
      profileId.value,
      topicId.value,
    );
    if (current == null) {
      throw _NotFound(topicId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('roadmap.topic_deleted');
    }
    return current;
  }

  Future<ChecklistItem> _loadChecklistItem(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    ChecklistItemId itemId,
  ) async {
    final ChecklistItem? current = await repo.findChecklistItem(
      profileId.value,
      itemId.value,
    );
    if (current == null) {
      throw _NotFound(itemId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('roadmap.checklist_deleted');
    }
    return current;
  }

  Future<void> _ensureNoteResolves(
    RoadmapWriteRepository repo,
    ProfileId profileId,
    NoteId? noteId,
  ) async {
    if (noteId == null) {
      return;
    }
    if (!await repo.liveNoteExists(profileId.value, noteId.value)) {
      throw const _Validation('roadmap.note_not_found');
    }
  }

  // ---- run + guards -------------------------------------------------------

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = GoalCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: GoalCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'roadmap.not_found',
          safeMessageKey: 'error.roadmap.not_found',
          retryable: false,
          redactedCause: e.entityId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.roadmap.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  T _guard<T>(T Function() build, String code) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation(code, cause: e.message);
    }
  }

  GoalRank _guardRank(GoalRank Function() build) {
    try {
      return build();
    } on ArgumentError catch (e) {
      throw _Validation('roadmap.invalid_rank', cause: e.message.toString());
    } on FormatException catch (e) {
      throw _Validation('roadmap.invalid_rank', cause: e.message);
    }
  }

  SemanticWrite _noop(String id) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$id"}',
  );

  ActivityDraft _activity(
    String eventType,
    String entityType,
    String entityId,
  ) => ActivityDraft(
    id: idGenerator.uuidV7(),
    eventType: eventType,
    entityType: entityType,
    entityId: entityId,
    payloadVersion: _payloadVersion,
  );

  List<DirtyProjectionDraft> _topicDirty(String topicId) =>
      <DirtyProjectionDraft>[
        DirtyProjectionDraft(
          projection: SearchDirtyKey.projection,
          projectionKey: SearchDirtyKey.encode(
            RoadmapTopicSearchProjector.kind,
            topicId,
          ),
        ),
      ];

  String _roadmapPayload(Roadmap roadmap) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': roadmap.id.value,
        'goal_id': roadmap.goalId.value,
        'title': roadmap.title,
        'status': roadmap.status.wire,
        'target_date': roadmap.targetDate,
        'revision': roadmap.revision,
      });

  String _sectionPayload(RoadmapSection section) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': section.id.value,
        'roadmap_id': section.roadmapId.value,
        'title': section.title,
        'rank': section.rank.value,
        'revision': section.revision,
      });

  String _topicPayload(RoadmapTopic topic) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': topic.id.value,
        'section_id': topic.sectionId.value,
        'title': topic.title,
        'status': topic.status.wire,
        'weight': topic.weight,
        'estimate_sec': topic.estimateSec,
        'note_id': topic.noteId?.value,
        'completed_at_utc': topic.completedAtUtc,
        'rank': topic.rank.value,
        'revision': topic.revision,
      });

  String _checklistPayload(ChecklistItem item) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': item.id.value,
        'roadmap_topic_id': item.roadmapTopicId.value,
        'text': item.text,
        'checked_at_utc': item.checkedAtUtc,
        'rank': item.rank.value,
        'revision': item.revision,
      });

  String _linkPayload(
    String? linkId,
    String topicId,
    String targetType,
    String targetId,
    String? rank,
  ) => GoalCanonicalRequest.encode(<String, Object?>{
    'id': linkId,
    'from_type': roadmapTopicFromType,
    'from_id': topicId,
    'relation': roadmapTopicLinkRelation,
    'to_type': targetType,
    'to_id': targetId,
    'rank': rank,
  });
}
