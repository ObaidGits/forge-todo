import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_event_kind.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_interval_kind.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';
import 'package:forge/features/focus/domain/focus_time_policy.dart';
import 'package:forge/features/focus/infrastructure/focus_canonical_request.dart';
import 'package:forge/features/focus/infrastructure/focus_write_repository.dart';

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

final class _Conflict implements Exception {
  const _Conflict(this.code);
  final String code;
}

/// Command-bus-backed implementation of [FocusCommandService]
/// (R-FOCUS-001..006, R-GEN-005).
///
/// Every command commits one atomic transaction with a durable receipt. The
/// lifecycle is append-only: start/pause/resume/end/cancel append immutable
/// events and interval projections, and [correct] appends an audit event
/// without rewriting prior history (R-FOCUS-003, R-FOCUS-005). Timer truth is
/// anchored to both the wall clock and the monotonic clock under a boot id, so
/// elapsed time survives reboot and clock discontinuity (R-FOCUS-002).
final class DriftFocusCommandService implements FocusCommandService {
  DriftFocusCommandService({
    required this.bus,
    required this.clock,
    required this.monotonic,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final MonotonicClock monotonic;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;
  static const int _microsPerSecond = 1000000;
  static const String _sessionEntity = 'focus_session';

  int get _now => clock.utcNow().microsecondsSinceEpoch;
  int get _monoMicros => monotonic.now().elapsedSinceBoot.inMicroseconds;
  String get _bootId => monotonic.bootSessionId();

  // ---- start --------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> start({
    required CommandId commandId,
    required ProfileId profileId,
    required StartFocusSessionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'start',
      'life_area_id': input.lifeAreaId,
      if (input.preset != null) 'preset': input.preset!.wire,
      if (input.mode != null) 'mode': input.mode!.wire,
      if (input.plannedDurationSec != null)
        'planned_duration_sec': input.plannedDurationSec,
      if (input.link != null) 'link_type': input.link!.type.wire,
      if (input.link != null) 'link_id': input.link!.targetId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.start',
      canonical: canonical,
      body: (TransactionSession session) =>
          _startBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _startBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    StartFocusSessionInput input,
  ) async {
    final FocusWriteRepository repo = session.repositories
        .resolve<FocusWriteRepository>();
    final FocusSession? open = await repo.findOpenSession(profileId.value);
    if (open != null) {
      throw const _Conflict('focus.session_already_open');
    }

    final FocusMode mode =
        input.preset?.mode ?? input.mode ?? FocusMode.countUp;
    final int? planned = mode == FocusMode.interval
        ? (input.preset?.plannedDurationSec ?? input.plannedDurationSec)
        : null;

    if (input.link != null) {
      final bool exists = await repo.linkTargetExists(
        profileId.value,
        input.link!,
      );
      if (!exists) {
        throw _NotFound('focus.link_target_not_found', input.link!.targetId);
      }
    }

    final int now = _now;
    final int mono = _monoMicros;
    final String boot = _bootId;
    final String sessionId = idGenerator.uuidV7();

    final FocusSession focus;
    try {
      focus = FocusSession(
        id: FocusSessionId(sessionId),
        profileId: profileId,
        lifeAreaId: LifeAreaId(input.lifeAreaId),
        link: input.link,
        mode: mode,
        preset: input.preset?.wire,
        plannedDurationSec: planned,
        status: FocusSessionStatus.running,
        wallAnchorUtc: now,
        monotonicAnchorMicros: mono,
        bootSessionId: boot,
        accumulatedDurationSec: 0,
        startedAtUtc: now,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('focus.invalid_session', cause: e.message);
    }
    await repo.insertSession(focus);
    await repo.insertInterval(
      FocusInterval(
        id: idGenerator.uuidV7(),
        profileId: profileId.value,
        sessionId: sessionId,
        kind: FocusIntervalKind.work,
        startedAtUtc: now,
        monotonicStartMicros: mono,
        bootSessionId: boot,
        createdAtUtc: now,
      ),
    );
    await repo.insertEvent(
      _event(
        profileId: profileId.value,
        sessionId: sessionId,
        kind: FocusEventKind.started,
        commandId: commandId.value,
        now: now,
        mono: mono,
        boot: boot,
      ),
    );

    return _write(
      resultCode: 'focus_started',
      resultPayload: '{"session_id":"$sessionId"}',
      activityEntityId: sessionId,
      eventType: 'focus_started',
      operations: <OutboxOperationDraft>[_sessionOp(focus, insert: true)],
    );
  }

  // ---- pause --------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> pause({
    required CommandId commandId,
    required ProfileId profileId,
    required PauseFocusSessionInput input,
  }) {
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.pause',
      canonical: <String, Object?>{
        'op': 'pause',
        'session_id': input.sessionId,
      },
      body: (TransactionSession session) => _transitionBody(
        session,
        profileId,
        commandId,
        input.sessionId,
        _Transition.pause,
      ),
    );
  }

  // ---- resume -------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> resume({
    required CommandId commandId,
    required ProfileId profileId,
    required ResumeFocusSessionInput input,
  }) {
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.resume',
      canonical: <String, Object?>{
        'op': 'resume',
        'session_id': input.sessionId,
      },
      body: (TransactionSession session) => _transitionBody(
        session,
        profileId,
        commandId,
        input.sessionId,
        _Transition.resume,
      ),
    );
  }

  // ---- end ----------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> end({
    required CommandId commandId,
    required ProfileId profileId,
    required EndFocusSessionInput input,
  }) {
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.end',
      canonical: <String, Object?>{'op': 'end', 'session_id': input.sessionId},
      body: (TransactionSession session) => _transitionBody(
        session,
        profileId,
        commandId,
        input.sessionId,
        _Transition.end,
      ),
    );
  }

  // ---- cancel -------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required CancelFocusSessionInput input,
  }) {
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.cancel',
      canonical: <String, Object?>{
        'op': 'cancel',
        'session_id': input.sessionId,
      },
      body: (TransactionSession session) => _transitionBody(
        session,
        profileId,
        commandId,
        input.sessionId,
        _Transition.cancel,
      ),
    );
  }

  Future<SemanticWrite> _transitionBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    String sessionId,
    _Transition transition,
  ) async {
    final FocusWriteRepository repo = session.repositories
        .resolve<FocusWriteRepository>();
    final FocusSession? existing = await repo.findSession(
      profileId.value,
      sessionId,
    );
    if (existing == null || existing.isDeleted) {
      throw _NotFound('focus.session_not_found', sessionId);
    }

    final int now = _now;
    final int mono = _monoMicros;
    final String boot = _bootId;

    switch (transition) {
      case _Transition.pause:
        if (existing.status != FocusSessionStatus.running) {
          throw const _Validation('focus.not_running');
        }
        final int segmentSec = await _closeOpenWork(repo, existing, now, mono);
        final FocusSession paused = existing.copyWith(
          status: FocusSessionStatus.paused,
          accumulatedDurationSec: existing.accumulatedDurationSec + segmentSec,
          revision: existing.revision + 1,
          updatedAtUtc: now,
        );
        await repo.updateSession(paused);
        await repo.insertInterval(
          FocusInterval(
            id: idGenerator.uuidV7(),
            profileId: profileId.value,
            sessionId: sessionId,
            kind: FocusIntervalKind.pause,
            startedAtUtc: now,
            monotonicStartMicros: mono,
            bootSessionId: boot,
            createdAtUtc: now,
          ),
        );
        await repo.insertEvent(
          _event(
            profileId: profileId.value,
            sessionId: sessionId,
            kind: FocusEventKind.paused,
            commandId: commandId.value,
            now: now,
            mono: mono,
            boot: boot,
          ),
        );
        return _transitionWrite(paused, 'focus_paused');

      case _Transition.resume:
        if (existing.status != FocusSessionStatus.paused) {
          throw const _Validation('focus.not_paused');
        }
        await _closeOpenInterval(repo, profileId.value, now, mono);
        // Re-anchor the new work segment to the current clocks and boot id so
        // elapsed measurement remains correct across a reboot (R-FOCUS-002).
        final FocusSession resumed = existing.copyWith(
          status: FocusSessionStatus.running,
          wallAnchorUtc: now,
          monotonicAnchorMicros: mono,
          bootSessionId: boot,
          revision: existing.revision + 1,
          updatedAtUtc: now,
        );
        await repo.updateSession(resumed);
        await repo.insertInterval(
          FocusInterval(
            id: idGenerator.uuidV7(),
            profileId: profileId.value,
            sessionId: sessionId,
            kind: FocusIntervalKind.work,
            startedAtUtc: now,
            monotonicStartMicros: mono,
            bootSessionId: boot,
            createdAtUtc: now,
          ),
        );
        await repo.insertEvent(
          _event(
            profileId: profileId.value,
            sessionId: sessionId,
            kind: FocusEventKind.resumed,
            commandId: commandId.value,
            now: now,
            mono: mono,
            boot: boot,
          ),
        );
        return _transitionWrite(resumed, 'focus_resumed');

      case _Transition.end:
      case _Transition.cancel:
        if (!existing.status.isOpen) {
          throw const _Validation('focus.not_open');
        }
        int accumulated = existing.accumulatedDurationSec;
        if (existing.status == FocusSessionStatus.running) {
          accumulated += await _closeOpenWork(repo, existing, now, mono);
        } else {
          // Paused: close the open pause interval without accumulating.
          await _closeOpenInterval(repo, profileId.value, now, mono);
        }
        final bool cancelling = transition == _Transition.cancel;
        final FocusSession terminal = existing.copyWith(
          status: cancelling
              ? FocusSessionStatus.cancelled
              : FocusSessionStatus.completed,
          accumulatedDurationSec: accumulated,
          endedAtUtc: now,
          revision: existing.revision + 1,
          updatedAtUtc: now,
        );
        await repo.updateSession(terminal);
        await repo.insertEvent(
          _event(
            profileId: profileId.value,
            sessionId: sessionId,
            kind: cancelling ? FocusEventKind.cancelled : FocusEventKind.ended,
            commandId: commandId.value,
            now: now,
            mono: mono,
            boot: boot,
          ),
        );
        return _transitionWrite(
          terminal,
          cancelling ? 'focus_cancelled' : 'focus_ended',
        );
    }
  }

  // ---- correct ------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> correct({
    required CommandId commandId,
    required ProfileId profileId,
    required CorrectFocusSessionInput input,
  }) {
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'focus.session.correct',
      canonical: <String, Object?>{
        'op': 'correct',
        'session_id': input.sessionId,
        'corrected_duration_sec': input.correctedDurationSec,
        if (input.reason != null) 'reason': input.reason,
      },
      body: (TransactionSession session) =>
          _correctBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _correctBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    CorrectFocusSessionInput input,
  ) async {
    final FocusWriteRepository repo = session.repositories
        .resolve<FocusWriteRepository>();
    final FocusSession? existing = await repo.findSession(
      profileId.value,
      input.sessionId,
    );
    if (existing == null || existing.isDeleted) {
      throw _NotFound('focus.session_not_found', input.sessionId);
    }
    if (input.correctedDurationSec < 0) {
      throw const _Validation('focus.invalid_correction');
    }

    final int now = _now;
    // Corrections update only the visible accumulated-duration projection and
    // append an audit event; prior events and intervals are never rewritten
    // (R-FOCUS-003, R-FOCUS-005).
    final FocusSession corrected = existing.copyWith(
      accumulatedDurationSec: input.correctedDurationSec,
      revision: existing.revision + 1,
      updatedAtUtc: now,
    );
    await repo.updateSession(corrected);
    await repo.insertEvent(
      _event(
        profileId: profileId.value,
        sessionId: input.sessionId,
        kind: FocusEventKind.corrected,
        commandId: commandId.value,
        now: now,
        mono: _monoMicros,
        boot: _bootId,
        payload: FocusCanonicalRequest.encode(<String, Object?>{
          'corrected_duration_sec': input.correctedDurationSec,
          if (input.reason != null) 'reason': input.reason,
        }),
      ),
    );
    return _transitionWrite(corrected, 'focus_corrected');
  }

  // ---- helpers ------------------------------------------------------------

  /// Closes the session's open work interval and returns the accumulated whole
  /// seconds of the segment, preferring the monotonic clock while the boot id
  /// matches (R-FOCUS-002).
  Future<int> _closeOpenWork(
    FocusWriteRepository repo,
    FocusSession session,
    int now,
    int mono,
  ) async {
    final FocusInterval? open = await repo.findOpenInterval(
      session.profileId.value,
    );
    if (open != null) {
      // Never stamp an end before the start: a backwards wall clock after a
      // reboot yields a zero-length interval rather than a negative one, which
      // matches the ambiguous zero-duration reconciliation below (R-FOCUS-002).
      final int end = now < open.startedAtUtc ? open.startedAtUtc : now;
      await repo.closeInterval(
        profileId: session.profileId.value,
        intervalId: open.id,
        endedAtUtc: end,
        monotonicEndMicros: mono,
      );
    }
    final ElapsedResolution resolution = FocusTimePolicy.resolveSegment(
      session.timerTruth,
      TimerReading(
        bootSessionId: _bootId,
        monotonic: Duration(microseconds: mono),
        wallUtcMicros: now,
      ),
    );
    final Duration segment = switch (resolution) {
      ElapsedKnown(segment: final Duration s) => s,
      ElapsedAmbiguous(lowerBound: final Duration lb) => lb,
    };
    return segment.inMicroseconds ~/ _microsPerSecond;
  }

  /// Closes whichever interval is currently open for the profile (used when the
  /// open interval is a pause, or when re-anchoring on resume).
  Future<void> _closeOpenInterval(
    FocusWriteRepository repo,
    String profileId,
    int now,
    int mono,
  ) async {
    final FocusInterval? open = await repo.findOpenInterval(profileId);
    if (open != null) {
      final int end = now < open.startedAtUtc ? open.startedAtUtc : now;
      await repo.closeInterval(
        profileId: profileId,
        intervalId: open.id,
        endedAtUtc: end,
        monotonicEndMicros: mono,
      );
    }
  }

  FocusEvent _event({
    required String profileId,
    required String sessionId,
    required FocusEventKind kind,
    required String commandId,
    required int now,
    required int mono,
    required String boot,
    String? payload,
  }) => FocusEvent(
    id: idGenerator.uuidV7(),
    profileId: profileId,
    sessionId: sessionId,
    kind: kind,
    commandId: commandId,
    wallAtUtc: now,
    monotonicMicros: mono,
    bootSessionId: boot,
    payload: payload,
    payloadVersion: _payloadVersion,
    occurredAtUtc: now,
  );

  SemanticWrite _transitionWrite(FocusSession session, String eventType) =>
      _write(
        resultCode: eventType,
        resultPayload:
            '{"session_id":"${session.id.value}",'
            '"status":"${session.status.wire}",'
            '"accumulated_duration_sec":${session.accumulatedDurationSec}}',
        activityEntityId: session.id.value,
        eventType: eventType,
        operations: <OutboxOperationDraft>[_sessionOp(session, insert: false)],
      );

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = FocusCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: FocusCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.focus.not_found',
          retryable: false,
          redactedCause: e.id,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.focus.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    } on _Conflict catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.conflict,
          code: e.code,
          safeMessageKey: 'error.focus.conflict',
          retryable: false,
        ),
      );
    }
  }

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required String activityEntityId,
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
          entityType: _sessionEntity,
          entityId: activityEntityId,
          payloadVersion: _payloadVersion,
        ),
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

  OutboxOperationDraft _sessionOp(
    FocusSession session, {
    required bool insert,
  }) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: _sessionEntity,
    entityId: session.id.value,
    opKind: insert ? 'insert' : 'patch',
    baseRowVersion: insert ? null : session.revision - 1,
    payload: FocusCanonicalRequest.encode(<String, Object?>{
      'id': session.id.value,
      'life_area_id': session.lifeAreaId.value,
      'link_target_type': session.link?.type.wire,
      'link_target_id': session.link?.targetId,
      'mode': session.mode.wire,
      'preset': session.preset,
      'planned_duration_sec': session.plannedDurationSec,
      'status': session.status.wire,
      'accumulated_duration_sec': session.accumulatedDurationSec,
      'started_at_utc': session.startedAtUtc,
      'ended_at_utc': session.endedAtUtc,
      'revision': session.revision,
    }),
  );
}

enum _Transition { pause, resume, end, cancel }
