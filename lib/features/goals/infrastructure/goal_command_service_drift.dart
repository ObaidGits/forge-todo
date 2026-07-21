import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_command_service.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/goals/infrastructure/goal_canonical_request.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/goal_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exceptions raised inside a command body; they roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper
// (mirrors the task and note command services).
final class _NotFound implements Exception {
  const _NotFound(this.entityId);
  final String entityId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed [GoalCommandService] (R-GOAL-001, R-GOAL-002, R-GOAL-004,
/// R-GOAL-006, R-GOAL-007, R-GEN-005).
///
/// Every mutation is one atomic transaction that writes the goal/milestone
/// row(s), marks the unified search projection dirty for goal text changes
/// (maintained in-commit by the registered [GoalSearchProjector]), and appends
/// activity — all alongside the cross-cutting receipt/activity/outbox/journal
/// write set. Milestone completion appends immutable activity history so the
/// audit trail survives toggling (R-GOAL-006), and archival is a distinct,
/// non-destructive state that keeps every row and link (R-GOAL-007).
final class DriftGoalCommandService implements GoalCommandService {
  DriftGoalCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  // ---- goal commands ------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateGoalInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create',
      'life_area_id': input.lifeAreaId.value,
      'title': input.title,
      'outcome_md': input.outcomeMd,
      'status': input.status.wire,
      'target_date': input.targetDate,
      'progress_mode': input.progressMode.wire,
      'manual_progress': input.manualProgress,
      'note_id': input.noteId?.value,
      'tag_ids': input.tagIds,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createBody(session, profileId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required UpdateGoalInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update',
      'goal_id': goalId.value,
      if (input.title != null) 'title': input.title,
      if (input.outcomeMd != null) 'outcome_md': input.outcomeMd,
      if (input.targetDate != null) 'target_date': input.targetDate!.value,
      if (input.noteId != null) 'note_id': input.noteId!.value?.value,
      if (input.lifeAreaId != null) 'life_area_id': input.lifeAreaId!.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateBody(session, profileId, goalId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setStatus({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required GoalStatus status,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_status',
      'goal_id': goalId.value,
      'status': status.wire,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.set_status',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setStatusBody(session, profileId, goalId, status),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setProgressPolicy({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required SetProgressPolicyInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_progress_policy',
      'goal_id': goalId.value,
      'mode': input.mode.wire,
      'manual_value': input.manualValue,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.set_progress_policy',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setProgressPolicyBody(session, profileId, goalId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setManualProgress({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required double value,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_manual_progress',
      'goal_id': goalId.value,
      'value': value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.set_manual_progress',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setManualProgressBody(session, profileId, goalId, value),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setArchived({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required bool archived,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_archived',
      'goal_id': goalId.value,
      'archived': archived,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.set_archived',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setArchivedBody(session, profileId, goalId, archived),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> move({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required MoveInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move',
      'goal_id': goalId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.move',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveGoalBody(session, profileId, goalId, input),
    );
  }

  // ---- milestone commands -------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required CreateMilestoneInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_milestone',
      'goal_id': goalId.value,
      'title': input.title,
      'target_date': input.targetDate,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.add_milestone',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addMilestoneBody(session, profileId, goalId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> updateMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
    required UpdateMilestoneInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_milestone',
      'milestone_id': milestoneId.value,
      if (input.title != null) 'title': input.title,
      if (input.targetDate != null) 'target_date': input.targetDate!.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.update_milestone',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateMilestoneBody(session, profileId, milestoneId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> completeMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
  }) => _milestoneCompletion(
    commandId: commandId,
    profileId: profileId,
    milestoneId: milestoneId,
    commandType: 'goal.complete_milestone',
    complete: true,
  );

  @override
  Future<Result<CommittedCommandResult>> uncompleteMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
  }) => _milestoneCompletion(
    commandId: commandId,
    profileId: profileId,
    milestoneId: milestoneId,
    commandType: 'goal.uncomplete_milestone',
    complete: false,
  );

  @override
  Future<Result<CommittedCommandResult>> moveMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
    required MoveInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move_milestone',
      'milestone_id': milestoneId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'goal.move_milestone',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveMilestoneBody(session, profileId, milestoneId, input),
    );
  }

  // ---- goal command bodies ------------------------------------------------

  Future<SemanticWrite> _createBody(
    TransactionSession session,
    ProfileId profileId,
    CreateGoalInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final int now = _now;

    // A manual goal stores a clamped value; a derived goal must not (R-GOAL-004).
    if (input.progressMode == GoalProgressMode.derived &&
        input.manualProgress != null) {
      throw const _Validation('goal.derived_no_manual_value');
    }
    final double? manual = input.progressMode == GoalProgressMode.manual
        ? GoalProgressPolicy.clampManual(input.manualProgress ?? 0)
        : null;

    await _ensureNoteResolves(repo, profileId, input.noteId);

    final GoalRank rank = GoalRank.append(
      await repo.lastGoalRank(profileId.value),
    );
    final String goalId = idGenerator.uuidV7();
    final Goal goal = _guardConstruct(
      () => Goal(
        id: GoalId(goalId),
        profileId: profileId,
        lifeAreaId: input.lifeAreaId,
        title: input.title,
        outcomeMd: input.outcomeMd,
        status: input.status,
        targetDate: input.targetDate,
        progressMode: input.progressMode,
        manualProgress: manual,
        noteId: input.noteId,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );

    await repo.insert(goal);
    for (final String tagId in input.tagIds) {
      await repo.attachTag(
        profileId: profileId.value,
        goalId: goalId,
        tagId: tagId,
        nowUtc: now,
      );
    }

    final int epoch = await repo.currentEpoch(profileId.value);
    return SemanticWrite(
      resultCode: 'created',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"$goalId"}',
      activity: <ActivityDraft>[_goalActivity('created', goalId)],
      dirtyProjections: _goalDirty(goalId),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: GoalSearchProjector.kind,
          entityId: goalId,
          opKind: 'insert',
          payload: _goalPayload(goal),
        ),
      ], epoch),
    );
  }

  Future<SemanticWrite> _updateBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    UpdateGoalInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    if (input.isEmpty) {
      return _noop(goalId.value);
    }
    if (input.noteId != null) {
      await _ensureNoteResolves(repo, profileId, input.noteId!.value);
    }

    final int now = _now;
    final Goal updated = _guardConstruct(
      () => current.copyWith(
        title: input.title,
        outcomeMd: input.outcomeMd,
        targetDate: input.targetDate == null
            ? Goal.unchanged
            : input.targetDate!.value,
        noteId: input.noteId == null ? Goal.unchanged : input.noteId!.value,
        lifeAreaId: input.lifeAreaId,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    await repo.update(updated);

    // Title/outcome are the goal's searchable content; refresh only when they
    // (may have) changed.
    final bool searchable = input.title != null || input.outcomeMd != null;
    return SemanticWrite(
      resultCode: 'updated',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"${goalId.value}"}',
      activity: <ActivityDraft>[_goalActivity('updated', goalId.value)],
      dirtyProjections: searchable
          ? _goalDirty(goalId.value)
          : const <DirtyProjectionDraft>[],
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: GoalSearchProjector.kind,
          entityId: goalId.value,
          opKind: 'patch',
          baseRowVersion: current.revision,
          payload: _goalPayload(updated),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  Future<SemanticWrite> _setStatusBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    GoalStatus status,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    if (current.status == status) {
      return _noop(goalId.value);
    }
    final int now = _now;
    final Goal updated = current.copyWith(
      status: status,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(updated);
    return _goalPatchWrite(
      repo,
      profileId,
      goalId.value,
      updated,
      current.revision,
      'status_changed',
      'status',
      resultCode: 'status_changed',
    );
  }

  Future<SemanticWrite> _setProgressPolicyBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    SetProgressPolicyInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    final int now = _now;

    final double? manual;
    if (input.mode == GoalProgressMode.manual) {
      // A clamped 0..1 value; default to the existing manual value or 0.
      final double raw = input.manualValue ?? current.manualProgress ?? 0;
      manual = GoalProgressPolicy.clampManual(raw);
    } else {
      if (input.manualValue != null) {
        throw const _Validation('goal.derived_no_manual_value');
      }
      manual = null;
    }

    // Idempotent no-op when the policy is unchanged.
    if (current.progressMode == input.mode &&
        current.manualProgress == manual) {
      return _noop(goalId.value);
    }

    // Passing `manualProgress: null` to copyWith clears the value (switching to
    // derived); passing a double sets it (switching to/updating manual).
    final Goal next = _guardConstruct(
      () => current.copyWith(
        progressMode: input.mode,
        manualProgress: manual,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    await repo.update(next);
    return _goalPatchWrite(
      repo,
      profileId,
      goalId.value,
      next,
      current.revision,
      'progress_policy_changed',
      'progress_mode,manual_progress',
      resultCode: 'progress_policy_changed',
    );
  }

  Future<SemanticWrite> _setManualProgressBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    double value,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    if (current.progressMode != GoalProgressMode.manual) {
      throw const _Validation('goal.not_manual_mode');
    }
    final double clamped = GoalProgressPolicy.clampManual(value);
    if (current.manualProgress == clamped) {
      return _noop(goalId.value);
    }
    final int now = _now;
    final Goal updated = current.copyWith(
      manualProgress: clamped,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(updated);
    return _goalPatchWrite(
      repo,
      profileId,
      goalId.value,
      updated,
      current.revision,
      'manual_progress_changed',
      'manual_progress',
      resultCode: 'manual_progress_changed',
    );
  }

  Future<SemanticWrite> _setArchivedBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    bool archived,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    if (current.isArchived == archived) {
      return _noop(goalId.value);
    }
    final int now = _now;
    // Archival is non-destructive: only archived_at_utc changes, so all
    // history and links are preserved (R-GOAL-007).
    final Goal updated = current.copyWith(
      archivedAtUtc: archived ? now : null,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(updated);
    return _goalPatchWrite(
      repo,
      profileId,
      goalId.value,
      updated,
      current.revision,
      archived ? 'archived' : 'unarchived',
      'archived_at_utc',
      resultCode: archived ? 'archived' : 'unarchived',
    );
  }

  Future<SemanticWrite> _moveGoalBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    MoveInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal current = await _loadGoal(repo, profileId, goalId);
    if (input.beforeRank == null && input.afterRank == null) {
      return _noop(goalId.value);
    }
    final GoalRank rank = _guardRank(
      () => GoalRank.between(
        input.beforeRank == null ? null : GoalRank.parse(input.beforeRank!),
        input.afterRank == null ? null : GoalRank.parse(input.afterRank!),
      ),
    );
    final int now = _now;
    final Goal moved = current.copyWith(
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(moved);
    return _goalPatchWrite(
      repo,
      profileId,
      goalId.value,
      moved,
      current.revision,
      'moved',
      'rank',
      resultCode: 'moved',
      resultPayload: '{"id":"${goalId.value}","rank":"${rank.value}"}',
      searchDirty: false,
    );
  }

  // ---- milestone command bodies -------------------------------------------

  Future<SemanticWrite> _addMilestoneBody(
    TransactionSession session,
    ProfileId profileId,
    GoalId goalId,
    CreateMilestoneInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    // The goal must exist and be live so the composite parent FK resolves.
    await _loadGoal(repo, profileId, goalId);
    final int now = _now;
    final GoalRank rank = GoalRank.append(
      await repo.lastMilestoneRank(profileId.value, goalId.value),
    );
    final String milestoneId = idGenerator.uuidV7();
    final Milestone milestone = _guardConstructMilestone(
      () => Milestone(
        id: MilestoneId(milestoneId),
        profileId: profileId,
        goalId: goalId,
        title: input.title,
        targetDate: input.targetDate,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );
    await repo.insertMilestone(milestone);
    return SemanticWrite(
      resultCode: 'milestone_created',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"$milestoneId","goal_id":"${goalId.value}"}',
      activity: <ActivityDraft>[
        _milestoneActivity('milestone_created', milestoneId),
      ],
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _milestoneEntity,
          entityId: milestoneId,
          opKind: 'insert',
          payload: _milestonePayload(milestone),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  Future<SemanticWrite> _updateMilestoneBody(
    TransactionSession session,
    ProfileId profileId,
    MilestoneId milestoneId,
    UpdateMilestoneInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Milestone current = await _loadMilestone(
      repo,
      profileId,
      milestoneId,
    );
    if (input.isEmpty) {
      return _noop(milestoneId.value);
    }
    final int now = _now;
    final Milestone updated = _guardConstructMilestone(
      () => current.copyWith(
        title: input.title,
        targetDate: input.targetDate == null
            ? Milestone.unchanged
            : input.targetDate!.value,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    await repo.updateMilestone(updated);
    return _milestonePatchWrite(
      repo,
      profileId,
      updated,
      current.revision,
      'milestone_updated',
      changedFields: 'title,target_date',
    );
  }

  Future<Result<CommittedCommandResult>> _milestoneCompletion({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
    required String commandType,
    required bool complete,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': complete ? 'complete_milestone' : 'uncomplete_milestone',
      'milestone_id': milestoneId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      canonical: canonical,
      body: (TransactionSession session) =>
          _milestoneCompletionBody(session, profileId, milestoneId, complete),
    );
  }

  Future<SemanticWrite> _milestoneCompletionBody(
    TransactionSession session,
    ProfileId profileId,
    MilestoneId milestoneId,
    bool complete,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Milestone current = await _loadMilestone(
      repo,
      profileId,
      milestoneId,
    );
    if (current.isCompleted == complete) {
      return _noop(milestoneId.value);
    }
    final int now = _now;
    final Milestone updated = current.copyWith(
      completedAtUtc: complete ? now : null,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateMilestone(updated);
    // Completion history is preserved through the append-only activity feed;
    // the row records only the current instant (R-GOAL-006).
    return _milestonePatchWrite(
      repo,
      profileId,
      updated,
      current.revision,
      complete ? 'milestone_completed' : 'milestone_uncompleted',
      changedFields: 'completed_at_utc',
      resultCode: complete ? 'milestone_completed' : 'milestone_uncompleted',
    );
  }

  Future<SemanticWrite> _moveMilestoneBody(
    TransactionSession session,
    ProfileId profileId,
    MilestoneId milestoneId,
    MoveInput input,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Milestone current = await _loadMilestone(
      repo,
      profileId,
      milestoneId,
    );
    if (input.beforeRank == null && input.afterRank == null) {
      return _noop(milestoneId.value);
    }
    final GoalRank rank = _guardRank(
      () => GoalRank.between(
        input.beforeRank == null ? null : GoalRank.parse(input.beforeRank!),
        input.afterRank == null ? null : GoalRank.parse(input.afterRank!),
      ),
    );
    final int now = _now;
    final Milestone moved = current.copyWith(
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateMilestone(moved);
    return _milestonePatchWrite(
      repo,
      profileId,
      moved,
      current.revision,
      'milestone_moved',
      changedFields: 'rank',
      resultCode: 'milestone_moved',
      resultPayload: '{"id":"${milestoneId.value}","rank":"${rank.value}"}',
    );
  }

  // ---- helpers ------------------------------------------------------------

  Future<Goal> _loadGoal(
    GoalWriteRepository repo,
    ProfileId profileId,
    GoalId goalId,
  ) async {
    final Goal? current = await repo.find(profileId.value, goalId.value);
    if (current == null) {
      throw _NotFound(goalId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('goal.deleted');
    }
    return current;
  }

  Future<Milestone> _loadMilestone(
    GoalWriteRepository repo,
    ProfileId profileId,
    MilestoneId milestoneId,
  ) async {
    final Milestone? current = await repo.findMilestone(
      profileId.value,
      milestoneId.value,
    );
    if (current == null) {
      throw _NotFound(milestoneId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('goal.milestone_deleted');
    }
    return current;
  }

  Future<void> _ensureNoteResolves(
    GoalWriteRepository repo,
    ProfileId profileId,
    NoteId? noteId,
  ) async {
    if (noteId == null) {
      return;
    }
    final bool exists = await repo.liveNoteExists(
      profileId.value,
      noteId.value,
    );
    if (!exists) {
      // Not found under this profile — includes cross-profile ids (R-GEN-002).
      throw const _Validation('goal.note_not_found');
    }
  }

  Future<SemanticWrite> _goalPatchWrite(
    GoalWriteRepository repo,
    ProfileId profileId,
    String goalId,
    Goal goal,
    int baseRevision,
    String eventType,
    String changedFields, {
    required String resultCode,
    String? resultPayload,
    bool searchDirty = true,
  }) async {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload ?? '{"id":"$goalId"}',
      activity: <ActivityDraft>[_goalActivity(eventType, goalId)],
      dirtyProjections: searchDirty
          ? _goalDirty(goalId)
          : const <DirtyProjectionDraft>[],
      outboxGroup: OutboxGroupDraft(
        groupId: idGenerator.uuidV7(),
        snapshotEpoch: await repo.currentEpoch(profileId.value),
        operations: <OutboxOperationDraft>[
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: GoalSearchProjector.kind,
            entityId: goalId,
            opKind: 'patch',
            changedFields: changedFields,
            baseRowVersion: baseRevision,
            payload: _goalPayload(goal),
          ),
        ],
      ),
    );
  }

  Future<SemanticWrite> _milestonePatchWrite(
    GoalWriteRepository repo,
    ProfileId profileId,
    Milestone milestone,
    int baseRevision,
    String eventType, {
    required String changedFields,
    String? resultCode,
    String? resultPayload,
  }) async {
    return SemanticWrite(
      resultCode: resultCode ?? eventType,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload ?? '{"id":"${milestone.id.value}"}',
      activity: <ActivityDraft>[
        _milestoneActivity(eventType, milestone.id.value),
      ],
      outboxGroup: OutboxGroupDraft(
        groupId: idGenerator.uuidV7(),
        snapshotEpoch: await repo.currentEpoch(profileId.value),
        operations: <OutboxOperationDraft>[
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: _milestoneEntity,
            entityId: milestone.id.value,
            opKind: 'patch',
            changedFields: changedFields,
            baseRowVersion: baseRevision,
            payload: _milestonePayload(milestone),
          ),
        ],
      ),
    );
  }

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
          code: 'goal.not_found',
          safeMessageKey: 'error.goal.not_found',
          retryable: false,
          redactedCause: e.entityId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.goal.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  Goal _guardConstruct(Goal Function() build) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation('goal.invalid_field', cause: e.message);
    }
  }

  Milestone _guardConstructMilestone(Milestone Function() build) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation('goal.milestone_invalid_field', cause: e.message);
    }
  }

  GoalRank _guardRank(GoalRank Function() build) {
    try {
      return build();
    } on ArgumentError catch (e) {
      throw _Validation('goal.invalid_rank', cause: e.message.toString());
    } on FormatException catch (e) {
      throw _Validation('goal.invalid_rank', cause: e.message);
    }
  }

  SemanticWrite _noop(String id) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$id"}',
  );

  ActivityDraft _goalActivity(String eventType, String goalId) => ActivityDraft(
    id: idGenerator.uuidV7(),
    eventType: eventType,
    entityType: GoalSearchProjector.kind,
    entityId: goalId,
    payloadVersion: _payloadVersion,
  );

  ActivityDraft _milestoneActivity(String eventType, String milestoneId) =>
      ActivityDraft(
        id: idGenerator.uuidV7(),
        eventType: eventType,
        entityType: _milestoneEntity,
        entityId: milestoneId,
        payloadVersion: _payloadVersion,
      );

  List<DirtyProjectionDraft> _goalDirty(
    String goalId,
  ) => <DirtyProjectionDraft>[
    DirtyProjectionDraft(
      projection: SearchDirtyKey.projection,
      projectionKey: SearchDirtyKey.encode(GoalSearchProjector.kind, goalId),
    ),
  ];

  OutboxGroupDraft? _group(List<OutboxOperationDraft> operations, int epoch) {
    if (operations.isEmpty) {
      return null;
    }
    return OutboxGroupDraft(
      groupId: idGenerator.uuidV7(),
      snapshotEpoch: epoch,
      operations: operations,
    );
  }

  static const String _milestoneEntity = 'milestone';

  String _goalPayload(Goal goal) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': goal.id.value,
        'life_area_id': goal.lifeAreaId.value,
        'title': goal.title,
        'outcome_md': goal.outcomeMd,
        'status': goal.status.wire,
        'target_date': goal.targetDate,
        'progress_mode': goal.progressMode.wire,
        'manual_progress': goal.manualProgress,
        'note_id': goal.noteId?.value,
        'archived_at_utc': goal.archivedAtUtc,
        'rank': goal.rank.value,
        'revision': goal.revision,
      });

  String _milestonePayload(Milestone milestone) =>
      GoalCanonicalRequest.encode(<String, Object?>{
        'id': milestone.id.value,
        'goal_id': milestone.goalId.value,
        'title': milestone.title,
        'target_date': milestone.targetDate,
        'completed_at_utc': milestone.completedAtUtc,
        'rank': milestone.rank.value,
        'revision': milestone.revision,
      });
}
