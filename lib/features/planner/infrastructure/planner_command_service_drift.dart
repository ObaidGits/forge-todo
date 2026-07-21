import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_command_service.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planner_policies.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_close_adjustment_kind.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_entry_role.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_rank.dart';
import 'package:forge/features/planner/infrastructure/planner_canonical_request.dart';
import 'package:forge/features/planner/infrastructure/planner_write_repository.dart';

// Private control-flow exceptions raised inside a command body. They roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.code, this.id);
  final String code;
  final String id;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [PlannerCommandService] (R-PLAN-001..004,
/// R-GEN-002, R-GEN-005).
///
/// Every command commits one atomic transaction with a durable receipt. The
/// factual close is idempotent and immutable: retrying the same command replays
/// the receipt, and a distinct command that would create a second close for an
/// already-closed period is rejected (R-PLAN-003).
final class DriftPlannerCommandService implements PlannerCommandService {
  DriftPlannerCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  // ---- savePlanningRecord -------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> savePlanningRecord({
    required CommandId commandId,
    required ProfileId profileId,
    required SavePlanningRecordInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'save_planning_record',
      'life_area_id': input.lifeAreaId,
      'kind': input.kind.wire,
      'period_key': input.periodKey,
      ..._sectionCanonical('morning_plan', input.morningPlanMd),
      ..._sectionCanonical('daily_plan', input.dailyPlanMd),
      ..._sectionCanonical('evening_reflection', input.eveningReflectionMd),
      ..._sectionCanonical('evening_prompts', input.eveningPromptsJson),
      ..._sectionCanonical('plan_intention', input.planIntentionMd),
      ..._sectionCanonical('reflection', input.reflectionMd),
      if (input.promptVersion != null) 'prompt_version': input.promptVersion,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.record.save',
      canonical: canonical,
      body: (TransactionSession session) =>
          _saveRecordBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _saveRecordBody(
    TransactionSession session,
    ProfileId profileId,
    SavePlanningRecordInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningPeriod? existing = await planner.findPeriodByKey(
      profileId.value,
      lifeAreaId: input.lifeAreaId,
      kind: input.kind,
      periodKey: input.periodKey,
    );

    final PlanningPeriod period;
    final String resultCode;
    if (existing == null) {
      period = _buildNewRecord(profileId, input, now);
      await planner.insertPeriod(period);
      resultCode = 'record_created';
    } else {
      if (existing.isDeleted) {
        throw const _Validation('planner.record_deleted');
      }
      period = _applyEdits(existing, input, now);
      await planner.updatePeriod(period);
      resultCode = 'record_updated';
    }

    return _write(
      resultCode: resultCode,
      resultPayload:
          '{"period_id":"${period.id.value}","kind":"${period.kind.wire}",'
          '"period_key":"${period.periodKey}"}',
      entityId: period.id.value,
      eventType: resultCode,
      operations: <OutboxOperationDraft>[_periodOp(period)],
    );
  }

  PlanningPeriod _buildNewRecord(
    ProfileId profileId,
    SavePlanningRecordInput input,
    int now,
  ) {
    String? section(SectionEdit edit) => edit.isSet ? edit.value : null;
    // The PlanningPeriod constructor enforces section-vs-kind applicability and
    // maps a violation to a validation failure through the outer wrapper.
    try {
      return PlanningPeriod(
        id: PlanningPeriodId(idGenerator.uuidV7()),
        profileId: profileId,
        lifeAreaId: LifeAreaId(input.lifeAreaId),
        kind: input.kind,
        periodKey: input.periodKey,
        morningPlanMd: section(input.morningPlanMd),
        dailyPlanMd: section(input.dailyPlanMd),
        eveningReflectionMd: section(input.eveningReflectionMd),
        eveningPromptsJson: section(input.eveningPromptsJson),
        planIntentionMd: section(input.planIntentionMd),
        reflectionMd: section(input.reflectionMd),
        promptVersion: input.promptVersion ?? 1,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('planner.invalid_section', cause: e.message);
    }
  }

  PlanningPeriod _applyEdits(
    PlanningPeriod existing,
    SavePlanningRecordInput input,
    int now,
  ) {
    Object? resolve(SectionEdit edit) {
      if (edit.isUnchanged) {
        return PlanningPeriod.unchangedSentinel;
      }
      return edit.isClear ? null : edit.value;
    }

    try {
      return existing.copyWith(
        morningPlanMd: resolve(input.morningPlanMd),
        dailyPlanMd: resolve(input.dailyPlanMd),
        eveningReflectionMd: resolve(input.eveningReflectionMd),
        eveningPromptsJson: resolve(input.eveningPromptsJson),
        planIntentionMd: resolve(input.planIntentionMd),
        reflectionMd: resolve(input.reflectionMd),
        promptVersion: input.promptVersion,
        revision: existing.revision + 1,
        updatedAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('planner.invalid_section', cause: e.message);
    }
  }

  // ---- addReference -------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addReference({
    required CommandId commandId,
    required ProfileId profileId,
    required AddReferenceInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_reference',
      'period_id': input.periodId,
      'entity_type': input.referenceType.wire,
      'entity_id': input.entityId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.reference.add',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addReferenceBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _addReferenceBody(
    TransactionSession session,
    ProfileId profileId,
    AddReferenceInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningPeriod? period = await planner.findPeriodById(
      profileId.value,
      input.periodId,
    );
    if (period == null) {
      throw _NotFound('planner.period_not_found', input.periodId);
    }
    if (period.isDeleted) {
      throw const _Validation('planner.record_deleted');
    }

    final String? lastRank = await planner.lastEntryRank(
      profileId.value,
      input.periodId,
    );
    final String entryId = idGenerator.uuidV7();
    final PlanningEntry entry = PlanningEntry(
      id: entryId,
      profileId: profileId.value,
      periodId: input.periodId,
      referenceType: input.referenceType,
      entityId: input.entityId,
      role: PlanningEntryRole.planned,
      rank: PlanningRank.append(lastRank),
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await planner.insertEntry(entry, addedEventId: idGenerator.uuidV7());

    return _write(
      resultCode: 'reference_added',
      resultPayload:
          '{"entry_id":"$entryId","entity_type":"${input.referenceType.wire}",'
          '"entity_id":"${input.entityId}"}',
      entityId: input.periodId,
      eventType: 'reference_added',
      operations: <OutboxOperationDraft>[_entryOp(entry)],
    );
  }

  // ---- removeReference ----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> removeReference({
    required CommandId commandId,
    required ProfileId profileId,
    required String entryId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'remove_reference',
      'entry_id': entryId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.reference.remove',
      canonical: canonical,
      body: (TransactionSession session) =>
          _removeReferenceBody(session, profileId, entryId),
    );
  }

  Future<SemanticWrite> _removeReferenceBody(
    TransactionSession session,
    ProfileId profileId,
    String entryId,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final PlanningEntry? entry = await planner.findEntry(
      profileId.value,
      entryId,
    );
    if (entry == null) {
      throw _NotFound('planner.entry_not_found', entryId);
    }
    await planner.deleteEntry(profileId.value, entryId);
    return _write(
      resultCode: 'reference_removed',
      resultPayload: '{"entry_id":"$entryId"}',
      entityId: entry.periodId,
      eventType: 'reference_removed',
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: 'planning_entry',
          entityId: entryId,
          opKind: 'delete',
          payload: PlannerCanonicalRequest.encode(<String, Object?>{
            'id': entryId,
          }),
        ),
      ],
    );
  }

  // ---- applyCarryForward --------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> applyCarryForward({
    required CommandId commandId,
    required ProfileId profileId,
    required CarryForwardInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'apply_carry_forward',
      'source_period_id': input.sourcePeriodId,
      'target_period_id': input.targetPeriodId,
      'source_entry_ids': (input.sourceEntryIds.toList()..sort()),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.carry_forward',
      canonical: canonical,
      body: (TransactionSession session) =>
          _carryForwardBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _carryForwardBody(
    TransactionSession session,
    ProfileId profileId,
    CarryForwardInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningPeriod? target = await planner.findPeriodById(
      profileId.value,
      input.targetPeriodId,
    );
    if (target == null) {
      throw _NotFound('planner.period_not_found', input.targetPeriodId);
    }
    if (target.isDeleted) {
      throw const _Validation('planner.record_deleted');
    }
    if (input.sourceEntryIds.isEmpty) {
      throw const _Validation('planner.carry_forward_empty');
    }

    String? lastRank = await planner.lastEntryRank(
      profileId.value,
      input.targetPeriodId,
    );
    final List<OutboxOperationDraft> ops = <OutboxOperationDraft>[];
    final List<String> carriedEntryIds = <String>[];
    for (final String sourceEntryId in input.sourceEntryIds) {
      final PlanningEntry? source = await planner.findEntry(
        profileId.value,
        sourceEntryId,
      );
      if (source == null) {
        throw _NotFound('planner.entry_not_found', sourceEntryId);
      }
      if (source.periodId != input.sourcePeriodId) {
        throw _Validation(
          'planner.carry_source_mismatch',
          cause: sourceEntryId,
        );
      }
      final String rank = PlanningRank.append(lastRank);
      lastRank = rank;
      final String entryId = idGenerator.uuidV7();
      // Carry-forward records the carry relation and never alters task due
      // dates: no task write happens here (R-PLAN-003).
      final PlanningEntry carried = PlanningEntry(
        id: entryId,
        profileId: profileId.value,
        periodId: input.targetPeriodId,
        referenceType: source.referenceType,
        entityId: source.entityId,
        role: PlanningEntryRole.carry,
        carriedFromEntryId: sourceEntryId,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      await planner.insertEntry(carried, addedEventId: idGenerator.uuidV7());
      carriedEntryIds.add(entryId);
      ops.add(_entryOp(carried));
    }

    return _write(
      resultCode: 'carry_forward_applied',
      resultPayload:
          '{"target_period_id":"${input.targetPeriodId}",'
          '"carried_count":${carriedEntryIds.length}}',
      entityId: input.targetPeriodId,
      eventType: 'carry_forward_applied',
      operations: ops,
    );
  }

  // ---- closePeriod --------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> closePeriod({
    required CommandId commandId,
    required ProfileId profileId,
    required ClosePeriodInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'close_period',
      'period_id': input.periodId,
      'boundary_utc': input.boundaryUtc,
      'metric_policy_version': input.metricPolicyVersion,
      'carried_task_ids': (input.carriedTaskIds.toList()..sort()),
      'tasks': <Map<String, Object?>>[
        for (final CloseTaskInput t in input.tasks)
          <String, Object?>{
            'id': t.taskId,
            'planned': t.isPlanned,
            'due': t.isDue,
            'completed': t.completedAtOrBeforeBoundary,
            'cancelled': t.cancelledBeforeClose,
          },
      ],
      'habits': <Map<String, Object?>>[
        for (final CloseHabitInput h in input.habits)
          <String, Object?>{'id': h.occurrenceId, 'status': h.status},
      ],
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.close',
      canonical: canonical,
      body: (TransactionSession session) =>
          _closePeriodBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _closePeriodBody(
    TransactionSession session,
    ProfileId profileId,
    ClosePeriodInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningPeriod? period = await planner.findPeriodById(
      profileId.value,
      input.periodId,
    );
    if (period == null) {
      throw _NotFound('planner.period_not_found', input.periodId);
    }
    // Exactly one immutable factual close per period. A distinct command that
    // would create a second close is rejected; an identical command replays its
    // receipt through the command bus before this body runs (R-PLAN-003).
    final PlanningCloseEvent? already = await planner.findCloseByPeriod(
      profileId.value,
      input.periodId,
    );
    if (already != null) {
      throw const _Validation('planner.already_closed');
    }

    final CloseTaskCounts counts;
    try {
      counts = PlannerPolicies.computeTaskClose(<CloseTaskFact>[
        for (final CloseTaskInput t in input.tasks)
          CloseTaskFact(
            entityId: t.taskId,
            isPlanned: t.isPlanned,
            isDue: t.isDue,
            completedAtOrBeforeBoundary: t.completedAtOrBeforeBoundary,
            cancelledBeforeClose: t.cancelledBeforeClose,
            taskDueDate: t.taskDueDate,
            sourceEventId: t.sourceEventId,
          ),
      ], carriedEntityIds: input.carriedTaskIds);
    } on FormatException catch (e) {
      throw _Validation('planner.invalid_carry', cause: e.message);
    }

    final String closeId = idGenerator.uuidV7();
    final PlanningCloseEvent event = PlanningCloseEvent(
      id: closeId,
      profileId: profileId.value,
      periodId: input.periodId,
      closedAtUtc: now,
      boundaryUtc: input.boundaryUtc,
      metricPolicyVersion: input.metricPolicyVersion,
      sourceCommitSeq: session.commitSeq,
      eligibleCount: counts.eligible,
      completedCount: counts.completed,
      missedCount: counts.missed,
      carriedCount: counts.carried,
      eligibleRootHash: counts.eligibleRootHash,
      completedRootHash: counts.completedRootHash,
      createdAtUtc: now,
    );
    await planner.insertCloseEvent(event);

    for (final ClassifiedCloseItem item in counts.items) {
      await planner.insertCloseItem(
        PlanningCloseItem(
          profileId: profileId.value,
          closeEventId: closeId,
          entityType: 'task',
          entityId: item.fact.entityId,
          isPlanned: item.fact.isPlanned,
          isDue: item.fact.isDue,
          taskDueDate: item.fact.taskDueDate,
          status: item.carried ? 'carried' : item.status.wire,
          sourceEventId: item.fact.sourceEventId,
        ),
        nowUtc: now,
      );
    }
    for (final CloseHabitInput habit in input.habits) {
      await planner.insertCloseItem(
        PlanningCloseItem(
          profileId: profileId.value,
          closeEventId: closeId,
          entityType: 'habit_occurrence',
          entityId: habit.occurrenceId,
          status: habit.status,
          sourceEventId: habit.sourceEventId,
        ),
        nowUtc: now,
      );
    }

    return _write(
      resultCode: 'period_closed',
      resultPayload:
          '{"close_event_id":"$closeId","eligible":${counts.eligible},'
          '"completed":${counts.completed},"missed":${counts.missed},'
          '"carried":${counts.carried}}',
      entityId: input.periodId,
      eventType: 'period_closed',
      operations: <OutboxOperationDraft>[_closeOp(event)],
    );
  }

  // ---- appendSourceCorrection ---------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> appendSourceCorrection({
    required CommandId commandId,
    required ProfileId profileId,
    required SourceCorrectionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'append_source_correction',
      'period_id': input.periodId,
      'affected_entity_type': input.affectedEntityType,
      'affected_entity_id': input.affectedEntityId,
      'affected_metric': input.affectedMetric,
      'prior': input.priorClassification,
      'current': input.currentClassification,
      'delta': input.delta,
      if (input.sourceEventId != null) 'source_event_id': input.sourceEventId,
      if (input.sourceCommitSeq != null)
        'source_commit_seq': input.sourceCommitSeq,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.adjustment.source_correction',
      canonical: canonical,
      body: (TransactionSession session) =>
          _sourceCorrectionBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _sourceCorrectionBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    SourceCorrectionInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningCloseEvent? close = await planner.findCloseByPeriod(
      profileId.value,
      input.periodId,
    );
    if (close == null) {
      throw _NotFound('planner.close_not_found', input.periodId);
    }

    final String adjustmentId = idGenerator.uuidV7();
    final PlanningCloseAdjustment adjustment = PlanningCloseAdjustment(
      id: adjustmentId,
      profileId: profileId.value,
      closeEventId: close.id,
      kind: PlanningCloseAdjustmentKind.sourceCorrection,
      metricPolicyVersion: close.metricPolicyVersion,
      occurredAtUtc: now,
      createdAtUtc: now,
      sourceCommandId: commandId.value,
      sourceEventId: input.sourceEventId,
      sourceCommitSeq: input.sourceCommitSeq,
      reason: input.reason,
      affectedEntityType: input.affectedEntityType,
      affectedEntityId: input.affectedEntityId,
      affectedMetric: input.affectedMetric,
      priorClassification: input.priorClassification,
      currentClassification: input.currentClassification,
      delta: input.delta,
    );
    await planner.insertAdjustment(adjustment);

    return _write(
      resultCode: 'source_correction_appended',
      resultPayload:
          '{"adjustment_id":"$adjustmentId","close_event_id":"${close.id}"}',
      entityId: input.periodId,
      eventType: 'source_correction_appended',
      operations: <OutboxOperationDraft>[_adjustmentOp(adjustment)],
    );
  }

  // ---- appendPolicyRecomputation ------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> appendPolicyRecomputation({
    required CommandId commandId,
    required ProfileId profileId,
    required PolicyRecomputationInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'append_policy_recomputation',
      'period_id': input.periodId,
      'metric_policy_version': input.metricPolicyVersion,
      'derived_summary': input.derivedSummaryJson,
      if (input.affectedMetric != null) 'affected_metric': input.affectedMetric,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'planner.adjustment.policy_recomputation',
      canonical: canonical,
      body: (TransactionSession session) =>
          _policyRecomputationBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _policyRecomputationBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    PolicyRecomputationInput input,
  ) async {
    final PlannerWriteRepository planner = session.repositories
        .resolve<PlannerWriteRepository>();
    final int now = _now;

    final PlanningCloseEvent? close = await planner.findCloseByPeriod(
      profileId.value,
      input.periodId,
    );
    if (close == null) {
      throw _NotFound('planner.close_not_found', input.periodId);
    }

    final String adjustmentId = idGenerator.uuidV7();
    final PlanningCloseAdjustment adjustment = PlanningCloseAdjustment(
      id: adjustmentId,
      profileId: profileId.value,
      closeEventId: close.id,
      kind: PlanningCloseAdjustmentKind.policyRecomputation,
      metricPolicyVersion: input.metricPolicyVersion,
      occurredAtUtc: now,
      createdAtUtc: now,
      sourceCommandId: commandId.value,
      reason: input.reason,
      affectedMetric: input.affectedMetric,
      derivedSummaryJson: input.derivedSummaryJson,
      derivedRootHash: PlannerPolicies.rootHash(<String>[
        input.derivedSummaryJson,
        'policy:${input.metricPolicyVersion}',
      ]),
    );
    await planner.insertAdjustment(adjustment);

    return _write(
      resultCode: 'policy_recomputation_appended',
      resultPayload:
          '{"adjustment_id":"$adjustmentId","close_event_id":"${close.id}",'
          '"metric_policy_version":${input.metricPolicyVersion}}',
      entityId: input.periodId,
      eventType: 'policy_recomputation_appended',
      operations: <OutboxOperationDraft>[_adjustmentOp(adjustment)],
    );
  }

  // ---- helpers ------------------------------------------------------------

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = PlannerCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: PlannerCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.planner.not_found',
          retryable: false,
          redactedCause: e.id,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.planner.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required String entityId,
    required String eventType,
    required List<OutboxOperationDraft> operations,
  }) {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: eventType,
          entityType: 'planning_period',
          entityId: entityId,
          payloadVersion: _payloadVersion,
        ),
      ],
      dirtyProjections: <DirtyProjectionDraft>[
        DirtyProjectionDraft(projection: 'search', projectionKey: entityId),
      ],
      outboxGroup: operations.isEmpty
          ? null
          : OutboxGroupDraft(
              groupId: idGenerator.uuidV7(),
              snapshotEpoch: 0,
              operations: operations,
            ),
    );
  }

  Map<String, Object?> _sectionCanonical(String name, SectionEdit edit) {
    if (edit.isUnchanged) {
      return const <String, Object?>{};
    }
    return <String, Object?>{name: edit.isClear ? null : edit.value};
  }

  OutboxOperationDraft _periodOp(PlanningPeriod period) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: 'planning_period',
    entityId: period.id.value,
    opKind: period.revision == 1 ? 'insert' : 'patch',
    baseRowVersion: period.revision == 1 ? null : period.revision - 1,
    payload: PlannerCanonicalRequest.encode(<String, Object?>{
      'id': period.id.value,
      'life_area_id': period.lifeAreaId.value,
      'kind': period.kind.wire,
      'period_key': period.periodKey,
      'morning_plan_md': period.morningPlanMd,
      'daily_plan_md': period.dailyPlanMd,
      'evening_reflection_md': period.eveningReflectionMd,
      'evening_prompts_json': period.eveningPromptsJson,
      'plan_intention_md': period.planIntentionMd,
      'reflection_md': period.reflectionMd,
      'prompt_version': period.promptVersion,
      'revision': period.revision,
    }),
  );

  OutboxOperationDraft _entryOp(PlanningEntry entry) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: 'planning_entry',
    entityId: entry.id,
    opKind: 'insert',
    payload: PlannerCanonicalRequest.encode(<String, Object?>{
      'id': entry.id,
      'period_id': entry.periodId,
      'entity_type': entry.referenceType.wire,
      'entity_id': entry.entityId,
      'role': entry.role.wire,
      'carried_from_entry_id': entry.carriedFromEntryId,
      'rank': entry.rank,
    }),
  );

  OutboxOperationDraft _closeOp(PlanningCloseEvent event) =>
      OutboxOperationDraft(
        operationId: idGenerator.uuidV7(),
        entityType: 'planning_close_event',
        entityId: event.id,
        opKind: 'insert',
        payload: PlannerCanonicalRequest.encode(<String, Object?>{
          'id': event.id,
          'period_id': event.periodId,
          'closed_at_utc': event.closedAtUtc,
          'boundary_utc': event.boundaryUtc,
          'metric_policy_version': event.metricPolicyVersion,
          'eligible_count': event.eligibleCount,
          'completed_count': event.completedCount,
          'missed_count': event.missedCount,
          'carried_count': event.carriedCount,
          'eligible_root_hash': event.eligibleRootHash,
          'completed_root_hash': event.completedRootHash,
        }),
      );

  OutboxOperationDraft _adjustmentOp(PlanningCloseAdjustment adjustment) =>
      OutboxOperationDraft(
        operationId: idGenerator.uuidV7(),
        entityType: 'planning_close_adjustment',
        entityId: adjustment.id,
        opKind: 'insert',
        payload: PlannerCanonicalRequest.encode(<String, Object?>{
          'id': adjustment.id,
          'close_event_id': adjustment.closeEventId,
          'kind': adjustment.kind.wire,
          'metric_policy_version': adjustment.metricPolicyVersion,
          'affected_entity_type': adjustment.affectedEntityType,
          'affected_entity_id': adjustment.affectedEntityId,
          'affected_metric': adjustment.affectedMetric,
          'prior_classification': adjustment.priorClassification,
          'current_classification': adjustment.currentClassification,
          'delta': adjustment.delta,
          'derived_summary_json': adjustment.derivedSummaryJson,
          'derived_root_hash': adjustment.derivedRootHash,
        }),
      );
}
