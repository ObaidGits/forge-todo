import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/domain/habit.dart';
import 'package:forge/features/habits/domain/habit_checkin.dart';
import 'package:forge/features/habits/domain/habit_occurrence_engine.dart';
import 'package:forge/features/habits/domain/habit_occurrence_key.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';
import 'package:forge/features/habits/domain/habit_projection_policy.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_schedule_version.dart';
import 'package:forge/features/habits/domain/habit_target.dart';
import 'package:forge/features/habits/domain/habit_unit_normalizer.dart';
import 'package:forge/features/habits/infrastructure/habit_canonical_request.dart';
import 'package:forge/features/habits/infrastructure/habit_search_projector.dart';
import 'package:forge/features/habits/infrastructure/habit_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exceptions raised inside a command body; they roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.habitId);
  final String habitId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [HabitCommandService]
/// (R-HABIT-001..007, R-GEN-005).
///
/// The service orchestrates immutable schedule/target versions, deterministic
/// occurrences, and append-only check-in supersession through the shared
/// command bus, so every mutation is one atomic transaction with a durable
/// receipt. Occurrence math and projections are delegated to pure domain
/// policies.
final class DriftHabitCommandService implements HabitCommandService {
  DriftHabitCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<Result<CommittedCommandResult>> createHabit({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CreateHabitInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create_habit',
      'habit_id': habitId.value,
      'life_area_id': input.lifeAreaId,
      'title': input.title,
      'rank': input.rank,
      ..._scheduleCanonical(input.rule, input.target),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createHabitBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> checkIn({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CheckInInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'check_in',
      'habit_id': habitId.value,
      'on_date': input.onDate.iso,
      'kind': input.kind.name,
      if (input.rawValue != null) 'raw_value': input.rawValue,
      if (input.rawUnit != null) 'raw_unit': input.rawUnit,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.check_in',
      canonical: canonical,
      body: (TransactionSession session) =>
          _checkInBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> correctObservation({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CorrectObservationInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'correct_observation',
      'habit_id': habitId.value,
      'logical_id': input.logicalId,
      'kind': input.kind.name,
      if (input.rawValue != null) 'raw_value': input.rawValue,
      if (input.rawUnit != null) 'raw_unit': input.rawUnit,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.correct_observation',
      canonical: canonical,
      body: (TransactionSession session) =>
          _correctBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> skipOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required SkipOccurrenceInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'skip_occurrence',
      'habit_id': habitId.value,
      'on_date': input.onDate.iso,
      if (input.reason != null) 'reason': input.reason,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.skip_occurrence',
      canonical: canonical,
      body: (TransactionSession session) =>
          _skipBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> closeOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CloseOccurrenceInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'close_occurrence',
      'habit_id': habitId.value,
      'on_date': input.onDate.iso,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.close_occurrence',
      canonical: canonical,
      body: (TransactionSession session) =>
          _closeBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> editSchedule({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required EditScheduleInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'edit_schedule',
      'habit_id': habitId.value,
      'effective': input.effectiveKey.iso,
      ..._scheduleCanonical(input.rule, input.target),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.edit_schedule',
      canonical: canonical,
      body: (TransactionSession session) =>
          _editScheduleBody(session, profileId, habitId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> pauseHabit({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required PauseHabitInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'pause_habit',
      'habit_id': habitId.value,
      'start': input.startDate.iso,
      if (input.endDate != null) 'end': input.endDate!.iso,
      if (input.reason != null) 'reason': input.reason,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'habit.pause',
      canonical: canonical,
      body: (TransactionSession session) =>
          _pauseBody(session, profileId, habitId, input),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createHabitBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    CreateHabitInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final HabitOccurrenceKey? firstKey = HabitOccurrenceEngine.first(
      input.rule,
    );
    if (firstKey == null) {
      throw const _Validation('habit.no_occurrences');
    }

    final String versionId = idGenerator.uuidV7();
    final HabitScheduleVersion version = HabitScheduleVersion(
      id: versionId,
      habitId: habitId.value,
      version: 1,
      effectiveOccurrenceKey: firstKey.anchor,
      rule: input.rule,
      target: input.target,
    );

    final Habit habit = Habit(
      id: habitId,
      lifeAreaId: LifeAreaId(input.lifeAreaId),
      title: input.title,
      currentScheduleVersionId: versionId,
      rank: input.rank,
      status: HabitStatus.active,
      revision: 1,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insertHabit(habit, profileId: profileId.value);
    await repo.insertScheduleVersion(
      version,
      profileId: profileId.value,
      nowUtc: now,
    );
    await repo.insertOccurrence(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      habitId: habitId.value,
      scheduleVersionId: versionId,
      occurrenceKey: firstKey,
      status: HabitOccurrenceStatus.open,
      nowUtc: now,
      sourceCommitSeq: session.commitSeq,
    );

    return _write(
      resultCode: 'habit_created',
      resultPayload:
          '{"habit_id":"${habitId.value}","schedule_version_id":"$versionId",'
          '"first_occurrence":"${firstKey.value}"}',
      habitId: habitId.value,
      eventType: 'habit_created',
      operations: <OutboxOperationDraft>[
        _habitOp(habit, insert: true),
        _scheduleOp(version, profileId.value),
      ],
    );
  }

  Future<SemanticWrite> _checkInBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    CheckInInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    if (habit.isDeleted) {
      throw const _Validation('habit.deleted');
    }

    final _ResolvedOccurrence resolved = await _resolveOccurrence(
      repo,
      profileId,
      habitId,
      input.onDate,
      now,
      session.commitSeq,
    );
    final HabitTarget target = resolved.version.target;

    final _Observation observation = _buildObservation(
      target,
      input.kind,
      input.rawValue,
      input.rawUnit,
    );

    final String logicalId = idGenerator.uuidV7();
    await repo.appendCheckin(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      habitId: habitId.value,
      occurrenceId: resolved.record.id,
      logicalId: logicalId,
      kind: observation.kind,
      version: 1,
      nowUtc: now,
      rawValue: input.rawValue?.toDouble(),
      rawUnit: input.rawUnit,
      normalizedValue: observation.normalizedValue,
      note: input.note,
    );

    await _reproject(repo, profileId, resolved, target, now, session.commitSeq);

    return _write(
      resultCode: 'checked_in',
      resultPayload:
          '{"habit_id":"${habitId.value}","occurrence":"${resolved.record.occurrenceKey}",'
          '"logical_id":"$logicalId"}',
      habitId: habitId.value,
      eventType: 'habit_checked_in',
      operations: const <OutboxOperationDraft>[],
    );
  }

  Future<SemanticWrite> _correctBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    CorrectObservationInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    final HabitCheckinRecord? prior = await repo.findCurrentCheckinByLogical(
      profileId.value,
      input.logicalId,
    );
    if (prior == null) {
      throw const _Validation('habit.observation_missing');
    }
    // The corrected observation belongs to an existing occurrence; find it via
    // the prior record's occurrence.
    final _ResolvedOccurrence resolved = await _resolveExistingByCheckin(
      repo,
      profileId,
      habitId,
      input.logicalId,
    );
    final HabitTarget target = resolved.version.target;
    final _Observation observation = _buildObservation(
      target,
      input.kind,
      input.rawValue,
      input.rawUnit,
    );

    // The correction supersedes the prior record (its `is_current` flag is
    // cleared and this record links to it) so provenance is preserved. It
    // carries the corrected observation's semantic kind so the projection reads
    // the corrected value directly (R-HABIT-005).
    await repo.appendCheckin(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      habitId: habitId.value,
      occurrenceId: resolved.record.id,
      logicalId: input.logicalId,
      kind: observation.kind,
      version: 2,
      nowUtc: now,
      rawValue: input.rawValue?.toDouble(),
      rawUnit: input.rawUnit,
      normalizedValue: observation.normalizedValue,
      note: input.note,
      supersedesId: prior.id,
    );

    await _reproject(repo, profileId, resolved, target, now, session.commitSeq);

    return _write(
      resultCode: 'observation_corrected',
      resultPayload:
          '{"habit_id":"${habitId.value}","logical_id":"${input.logicalId}"}',
      habitId: habitId.value,
      eventType: 'habit_observation_corrected',
      operations: const <OutboxOperationDraft>[],
    );
  }

  Future<SemanticWrite> _skipBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    SkipOccurrenceInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    final _ResolvedOccurrence resolved = await _resolveOccurrence(
      repo,
      profileId,
      habitId,
      input.onDate,
      now,
      session.commitSeq,
    );
    await repo.updateOccurrenceProjection(
      profileId: profileId.value,
      occurrenceId: resolved.record.id,
      status: HabitOccurrenceStatus.skipped,
      normalizedTotal: resolved.record.normalizedTotal,
      nowUtc: now,
    );
    return _write(
      resultCode: 'occurrence_skipped',
      resultPayload:
          '{"habit_id":"${habitId.value}","occurrence":"${resolved.record.occurrenceKey}"}',
      habitId: habitId.value,
      eventType: 'habit_occurrence_skipped',
      operations: const <OutboxOperationDraft>[],
    );
  }

  Future<SemanticWrite> _closeBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    CloseOccurrenceInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    final _ResolvedOccurrence resolved = await _resolveOccurrence(
      repo,
      profileId,
      habitId,
      input.onDate,
      now,
      session.commitSeq,
    );
    if (resolved.record.status == HabitOccurrenceStatus.skipped) {
      // A skip is decisive and is not overwritten by close.
      return _write(
        resultCode: 'occurrence_closed',
        resultPayload:
            '{"habit_id":"${habitId.value}","occurrence":"${resolved.record.occurrenceKey}","status":"skipped"}',
        habitId: habitId.value,
        eventType: 'habit_occurrence_closed',
        operations: const <OutboxOperationDraft>[],
      );
    }
    await _reproject(
      repo,
      profileId,
      resolved,
      resolved.version.target,
      now,
      session.commitSeq,
      closed: true,
    );
    final _ResolvedOccurrence after = await _resolveExisting(
      repo,
      profileId,
      habitId,
      resolved.record.occurrenceKey,
      resolved.version,
    );
    return _write(
      resultCode: 'occurrence_closed',
      resultPayload:
          '{"habit_id":"${habitId.value}","occurrence":"${resolved.record.occurrenceKey}",'
          '"status":"${after.record.status.wire}"}',
      habitId: habitId.value,
      eventType: 'habit_occurrence_closed',
      operations: const <OutboxOperationDraft>[],
    );
  }

  Future<SemanticWrite> _editScheduleBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    EditScheduleInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    final HabitScheduleVersion? current = await repo.findOpenScheduleVersion(
      profileId.value,
      habitId.value,
    );
    if (current == null) {
      throw const _Validation('habit.no_open_version');
    }
    if (input.effectiveKey < current.effectiveOccurrenceKey) {
      throw const _Validation('habit.effective_before_version');
    }
    if (input.rule.start.iso != input.effectiveKey.iso) {
      // The successor rule must be anchored at the effective key so its pattern
      // starts there while historical keys stay immutable.
      throw const _Validation('habit.successor_not_anchored');
    }

    final String successorId = idGenerator.uuidV7();
    await repo.closeScheduleVersion(
      profileId.value,
      current.id,
      input.effectiveKey,
      now,
    );
    final HabitScheduleVersion successor = HabitScheduleVersion(
      id: successorId,
      habitId: habitId.value,
      version: current.version + 1,
      effectiveOccurrenceKey: input.effectiveKey,
      predecessorId: current.id,
      rule: input.rule,
      target: input.target,
      ruleVersion: current.ruleVersion,
    );
    await repo.insertScheduleVersion(
      successor,
      profileId: profileId.value,
      nowUtc: now,
    );
    final Habit updated = habit.copyWith(
      currentScheduleVersionId: successorId,
      revision: habit.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateHabit(updated, profileId: profileId.value);

    return _write(
      resultCode: 'schedule_edited',
      resultPayload:
          '{"habit_id":"${habitId.value}","predecessor":"${current.id}",'
          '"successor":"$successorId","effective":"${input.effectiveKey.iso}"}',
      habitId: habitId.value,
      eventType: 'habit_schedule_edited',
      operations: <OutboxOperationDraft>[
        _habitOp(updated, insert: false),
        _scheduleOp(successor, profileId.value),
      ],
    );
  }

  Future<SemanticWrite> _pauseBody(
    TransactionSession session,
    ProfileId profileId,
    HabitId habitId,
    PauseHabitInput input,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final int now = _now;

    final Habit? habit = await repo.findHabit(profileId.value, habitId.value);
    if (habit == null) {
      throw _NotFound(habitId.value);
    }
    await repo.insertPause(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      habitId: habitId.value,
      startDate: input.startDate,
      nowUtc: now,
      endDate: input.endDate,
      reason: input.reason,
    );
    final Habit updated = habit.copyWith(
      pausedAtUtc: now,
      revision: habit.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateHabit(updated, profileId: profileId.value);

    return _write(
      resultCode: 'habit_paused',
      resultPayload:
          '{"habit_id":"${habitId.value}","start":"${input.startDate.iso}"}',
      habitId: habitId.value,
      eventType: 'habit_paused',
      operations: <OutboxOperationDraft>[_habitOp(updated, insert: false)],
    );
  }

  // ---- helpers ------------------------------------------------------------

  /// Resolves (materializing if needed) the occurrence for [onDate], binding
  /// the schedule version effective at that key.
  Future<_ResolvedOccurrence> _resolveOccurrence(
    HabitWriteRepository repo,
    ProfileId profileId,
    HabitId habitId,
    LocalDate onDate,
    int now,
    int commitSeq,
  ) async {
    final HabitScheduleVersion? version = await repo.findVersionEffectiveAt(
      profileId.value,
      habitId.value,
      onDate,
    );
    if (version == null) {
      throw const _Validation('habit.no_effective_version');
    }
    final HabitOccurrenceKey? key = HabitOccurrenceEngine.keyFor(
      version.rule,
      onDate,
    );
    if (key == null) {
      throw const _Validation('habit.not_a_scheduled_occurrence');
    }
    final HabitOccurrenceRecord? existing = await repo.findOccurrenceByKey(
      profileId.value,
      habitId.value,
      key.value,
    );
    if (existing != null) {
      return _ResolvedOccurrence(record: existing, version: version);
    }
    final bool paused = await repo.isAnchorPaused(
      profileId.value,
      habitId.value,
      key.anchor,
    );
    final String occurrenceId = idGenerator.uuidV7();
    await repo.insertOccurrence(
      profileId: profileId.value,
      id: occurrenceId,
      habitId: habitId.value,
      scheduleVersionId: version.id,
      occurrenceKey: key,
      status: HabitOccurrenceStatus.open,
      nowUtc: now,
      isPaused: paused,
      sourceCommitSeq: commitSeq,
    );
    final HabitOccurrenceRecord? created = await repo.findOccurrenceByKey(
      profileId.value,
      habitId.value,
      key.value,
    );
    return _ResolvedOccurrence(record: created!, version: version);
  }

  Future<_ResolvedOccurrence> _resolveExisting(
    HabitWriteRepository repo,
    ProfileId profileId,
    HabitId habitId,
    String occurrenceKey,
    HabitScheduleVersion version,
  ) async {
    final HabitOccurrenceRecord? record = await repo.findOccurrenceByKey(
      profileId.value,
      habitId.value,
      occurrenceKey,
    );
    return _ResolvedOccurrence(record: record!, version: version);
  }

  Future<_ResolvedOccurrence> _resolveExistingByCheckin(
    HabitWriteRepository repo,
    ProfileId profileId,
    HabitId habitId,
    String logicalId,
  ) async {
    // The current record for the logical id already exists; re-fetch its
    // occurrence through the current check-in row's occurrence via the current
    // list is not available, so we resolve via the observation's occurrence by
    // scanning the current record. Simpler: the correction reuses the same
    // occurrence, found by walking the occurrence the observation belongs to.
    // We look up the occurrence via the checkin's stored occurrence id using a
    // dedicated query on the repository.
    final HabitOccurrenceRecord? record = await repo
        .findOccurrenceForLogicalCheckin(profileId.value, logicalId);
    if (record == null) {
      throw const _Validation('habit.observation_missing');
    }
    final HabitScheduleVersion? version = await repo.findScheduleVersion(
      profileId.value,
      record.scheduleVersionId,
    );
    if (version == null) {
      throw const _Validation('habit.version_missing');
    }
    return _ResolvedOccurrence(record: record, version: version);
  }

  Future<void> _reproject(
    HabitWriteRepository repo,
    ProfileId profileId,
    _ResolvedOccurrence resolved,
    HabitTarget target,
    int now,
    int commitSeq, {
    bool closed = false,
  }) async {
    final List<HabitCheckinRecord> checkins = await repo.currentCheckins(
      profileId.value,
      resolved.record.id,
    );
    final bool isClosed = closed || resolved.record.closedAtUtc != null;
    final HabitProjection projection = HabitProjectionPolicy.project(
      target: target,
      observations: checkins.map(_toObservation).toList(growable: false),
      isClosed: isClosed,
    );
    await repo.updateOccurrenceProjection(
      profileId: profileId.value,
      occurrenceId: resolved.record.id,
      status: projection.status,
      normalizedTotal: projection.normalizedTotal,
      nowUtc: now,
      closedAtUtc: closed ? now : null,
      sourceCommitSeq: commitSeq,
    );
  }

  HabitObservation _toObservation(HabitCheckinRecord record) {
    switch (record.kind) {
      case HabitCheckinKind.booleanTrue:
        return const HabitObservation.booleanTrue();
      case HabitCheckinKind.violation:
        return const HabitObservation.violation();
      case HabitCheckinKind.value:
      case HabitCheckinKind.correct:
        // A correction carries the corrected numeric/boolean payload. When it
        // superseded a boolean/violation the normalized value is 0; the target
        // decides interpretation in the projection policy.
        return HabitObservation.value(record.normalizedValue);
    }
  }

  _Observation _buildObservation(
    HabitTarget target,
    ObservationInputKind kind,
    num? rawValue,
    String? rawUnit,
  ) {
    switch (kind) {
      case ObservationInputKind.booleanTrue:
        if (target.kind != HabitTargetKind.boolean) {
          throw _Validation('habit.kind_mismatch', cause: target.kind.wire);
        }
        return const _Observation(HabitCheckinKind.booleanTrue, 0);
      case ObservationInputKind.violation:
        if (target.kind != HabitTargetKind.abstinence) {
          throw _Validation('habit.kind_mismatch', cause: target.kind.wire);
        }
        return const _Observation(HabitCheckinKind.violation, 0);
      case ObservationInputKind.value:
        if (!target.kind.isNumeric) {
          throw _Validation('habit.kind_mismatch', cause: target.kind.wire);
        }
        final int normalized = _normalizeNumeric(target, rawValue, rawUnit);
        return _Observation(HabitCheckinKind.value, normalized);
      case ObservationInputKind.clearViolation:
        // Retracting a violation is only meaningful for an abstinence target;
        // it appends a non-violation `correct` record that supersedes the prior
        // violation so the projection no longer sees a violation (R-HABIT-005).
        if (target.kind != HabitTargetKind.abstinence) {
          throw _Validation('habit.kind_mismatch', cause: target.kind.wire);
        }
        return const _Observation(HabitCheckinKind.correct, 0);
    }
  }

  int _normalizeNumeric(HabitTarget target, num? rawValue, String? rawUnit) {
    try {
      switch (target.kind) {
        case HabitTargetKind.count:
          final num value = rawValue ?? 1;
          if (value < 0) {
            throw const UnitConversionError('negative_value');
          }
          if (value != value.roundToDouble()) {
            throw const UnitConversionError('non_integer_count');
          }
          return value.round();
        case HabitTargetKind.duration:
          final String unit = rawUnit ?? target.displayUnit!;
          return HabitUnitNormalizer.durationToSeconds(
            displayUnit: unit,
            value: rawValue ?? 0,
          );
        case HabitTargetKind.quantity:
          if (rawUnit == null) {
            throw const UnitConversionError('unknown_unit');
          }
          return HabitUnitNormalizer.normalizeToTarget(
            targetUnit: target.unit!,
            observationUnit: rawUnit,
            value: rawValue ?? 0,
          );
        case HabitTargetKind.boolean:
        case HabitTargetKind.abstinence:
          throw const UnitConversionError('unknown_unit');
      }
    } on UnitConversionError catch (e) {
      throw _Validation('habit.invalid_observation', cause: e.code);
    }
  }

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = HabitCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: HabitCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'habit.not_found',
          safeMessageKey: 'error.habit.not_found',
          retryable: false,
          redactedCause: e.habitId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.habit.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required String habitId,
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
          entityType: 'habit',
          entityId: habitId,
          payloadVersion: _payloadVersion,
        ),
      ],
      dirtyProjections: <DirtyProjectionDraft>[
        // The unified search marker encodes the entity type so the projector
        // registry can route it to the habit projector (design.md §14); a bare
        // id cannot be routed and would strand the marker. Today stays keyed by
        // habit id.
        DirtyProjectionDraft(
          projection: SearchDirtyKey.projection,
          projectionKey: SearchDirtyKey.encode(
            HabitSearchProjector.kind,
            habitId,
          ),
        ),
        DirtyProjectionDraft(projection: 'today', projectionKey: habitId),
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

  Map<String, Object?> _scheduleCanonical(
    HabitScheduleRule rule,
    HabitTarget target,
  ) {
    return <String, Object?>{
      'frequency': rule.frequency.wire,
      'schedule_kind': rule.scheduleKind.wire,
      'interval': rule.interval,
      'start': rule.start.iso,
      'timezone': rule.timezoneId,
      'week_start': rule.weekStart,
      if (rule.weekdays.isNotEmpty)
        'weekdays': (rule.weekdays.toList()..sort()),
      if (rule.monthDays.isNotEmpty)
        'month_days': (rule.monthDays.toList()..sort()),
      'target_kind': target.kind.wire,
      if (target.targetValue != null) 'target_value': target.targetValue,
      if (target.unit != null) 'unit': target.unit,
      if (target.displayUnit != null) 'display_unit': target.displayUnit,
    };
  }

  OutboxOperationDraft _habitOp(Habit habit, {required bool insert}) =>
      OutboxOperationDraft(
        operationId: idGenerator.uuidV7(),
        entityType: 'habit',
        entityId: habit.id.value,
        opKind: insert ? 'insert' : 'patch',
        baseRowVersion: insert ? null : habit.revision - 1,
        payload: HabitCanonicalRequest.encode(<String, Object?>{
          'id': habit.id.value,
          'life_area_id': habit.lifeAreaId.value,
          'title': habit.title,
          'current_schedule_version_id': habit.currentScheduleVersionId,
          'status': habit.status.wire,
          'paused_at_utc': habit.pausedAtUtc,
          'rank': habit.rank,
          'revision': habit.revision,
        }),
      );

  OutboxOperationDraft _scheduleOp(
    HabitScheduleVersion version,
    String profileId,
  ) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: 'habit_schedule',
    entityId: version.id,
    opKind: 'insert',
    payload: HabitCanonicalRequest.encode(<String, Object?>{
      'id': version.id,
      'habit_id': version.habitId,
      'version': version.version,
      'effective': version.effectiveOccurrenceKey.iso,
      'target_kind': version.target.kind.wire,
    }),
  );
}

final class _ResolvedOccurrence {
  const _ResolvedOccurrence({required this.record, required this.version});

  final HabitOccurrenceRecord record;
  final HabitScheduleVersion version;
}

final class _Observation {
  const _Observation(this.kind, this.normalizedValue);

  final HabitCheckinKind kind;
  final int normalizedValue;
}
