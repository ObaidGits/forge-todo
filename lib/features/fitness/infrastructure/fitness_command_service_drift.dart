import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_command_service.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/application/water_tracking_settings.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/fitness_unit_normalizer.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/infrastructure/fitness_canonical_request.dart';
import 'package:forge/features/fitness/infrastructure/fitness_replication_payload.dart';
import 'package:forge/features/fitness/infrastructure/fitness_write_repository.dart';
import 'package:forge/features/fitness/infrastructure/workout_search_projector.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exception raised inside a command body; it rolls the
// transaction back and is mapped to a stable [Failure] by the outer wrapper.
final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [FitnessCommandService] (R-FIT-001,
/// R-FIT-002, R-GEN-005).
///
/// Each command writes its direct-area owner and inherited-area children in one
/// atomic transaction with a durable receipt. Unit preservation and conversion
/// are delegated to the pure [MeasuredQuantity]/[FitnessUnitNormalizer] domain.
///
/// The fitness records were joined to the optional sync replication in task
/// 12.1: every command now enqueues a semantic outbox group whose operations
/// are ordered parent-before-child (template → template exercises;
/// session → exercise log → set log). The group carries only the
/// manifest-replicated fields via [FitnessReplicationPayload] (entered units
/// preserved; derived canonical amounts recomputed on apply). Sync stays
/// optional and local-first: the outbox group is committed atomically with the
/// domain rows but only leaves the device once a sync profile is linked.
final class DriftFitnessCommandService implements FitnessCommandService {
  DriftFitnessCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
    required this.waterTracking,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  /// The local, disabled-by-default water-tracking preference gate (R-FIT-003).
  final WaterTrackingSettings waterTracking;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<Result<CommittedCommandResult>> createWorkoutTemplate({
    required CommandId commandId,
    required ProfileId profileId,
    required WorkoutTemplateId templateId,
    required CreateWorkoutTemplateInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create_workout_template',
      'template_id': templateId.value,
      'life_area_id': input.lifeAreaId,
      'title': input.title,
      'rank': input.rank,
      if (input.noteId != null) 'note_id': input.noteId,
      'exercises': <Map<String, Object?>>[
        for (final TemplateExerciseInput e in input.exercises)
          <String, Object?>{
            'name': e.name,
            'rank': e.rank,
            if (e.targetSets != null) 'target_sets': e.targetSets,
            if (e.targetReps != null) 'target_reps': e.targetReps,
            if (e.notes != null) 'notes': e.notes,
          },
      ],
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'fitness.create_workout_template',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createTemplateBody(session, profileId, templateId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> logWorkoutSession({
    required CommandId commandId,
    required ProfileId profileId,
    required WorkoutSessionId sessionId,
    required LogWorkoutSessionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'log_workout_session',
      'session_id': sessionId.value,
      'life_area_id': input.lifeAreaId,
      'title': input.title,
      if (input.templateId != null) 'template_id': input.templateId,
      'started_at_utc': input.startedAtUtc,
      if (input.endedAtUtc != null) 'ended_at_utc': input.endedAtUtc,
      if (input.durationSec != null) 'duration_sec': input.durationSec,
      if (input.noteId != null) 'note_id': input.noteId,
      'exercises': <Map<String, Object?>>[
        for (final ExerciseLogInput e in input.exercises)
          <String, Object?>{
            'name': e.name,
            'rank': e.rank,
            if (e.notes != null) 'notes': e.notes,
            'sets': <Map<String, Object?>>[
              for (final SetLogInput s in e.sets)
                <String, Object?>{
                  'rank': s.rank,
                  if (s.reps != null) 'reps': s.reps,
                  if (s.weightValue != null) 'weight_value': s.weightValue,
                  if (s.weightUnit != null) 'weight_unit': s.weightUnit,
                  if (s.durationSec != null) 'duration_sec': s.durationSec,
                  if (s.distanceValue != null)
                    'distance_value': s.distanceValue,
                  if (s.distanceUnit != null) 'distance_unit': s.distanceUnit,
                  if (s.completedAtUtc != null)
                    'completed_at_utc': s.completedAtUtc,
                },
            ],
          },
      ],
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'fitness.log_workout_session',
      canonical: canonical,
      body: (TransactionSession session) =>
          _logSessionBody(session, profileId, sessionId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> recordBodyMeasurement({
    required CommandId commandId,
    required ProfileId profileId,
    required BodyMeasurementId measurementId,
    required RecordBodyMeasurementInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'record_body_measurement',
      'measurement_id': measurementId.value,
      'life_area_id': input.lifeAreaId,
      'value': input.value,
      'unit': input.unit,
      'measured_at_utc': input.measuredAtUtc,
      if (input.note != null) 'note': input.note,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'fitness.record_body_measurement',
      canonical: canonical,
      body: (TransactionSession session) =>
          _recordMeasurementBody(session, profileId, measurementId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> logWaterEvent({
    required CommandId commandId,
    required ProfileId profileId,
    required WaterEventId eventId,
    required LogWaterEventInput input,
  }) async {
    // Optional and disabled by default (R-FIT-003): when the local preference
    // is off, no water event is written and no water logging surfaces. The gate
    // is checked before the command runs so nothing is persisted.
    final bool enabled = await waterTracking.isEnabled(profileId);
    if (!enabled) {
      return Failed<CommittedCommandResult>(
        const Failure(
          kind: FailureKind.validation,
          code: 'fitness.water_disabled',
          safeMessageKey: 'error.fitness.water_disabled',
          retryable: false,
        ),
      );
    }

    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'log_water_event',
      'event_id': eventId.value,
      'life_area_id': input.lifeAreaId,
      'value': input.value,
      'unit': input.unit,
      'occurred_at_utc': input.occurredAtUtc,
      if (input.note != null) 'note': input.note,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'fitness.log_water_event',
      canonical: canonical,
      body: (TransactionSession session) =>
          _logWaterEventBody(session, profileId, eventId, input),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createTemplateBody(
    TransactionSession session,
    ProfileId profileId,
    WorkoutTemplateId templateId,
    CreateWorkoutTemplateInput input,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    final int now = _now;

    if (input.title.trim().isEmpty) {
      throw const _Validation('fitness.title_required');
    }

    final WorkoutTemplate template = WorkoutTemplate(
      id: templateId,
      lifeAreaId: LifeAreaId(input.lifeAreaId),
      title: input.title,
      rank: input.rank,
      status: WorkoutTemplateStatus.active,
      noteId: input.noteId,
      revision: 1,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insertTemplate(template, profileId: profileId.value);

    // Parent-before-child: the template insert precedes its exercise inserts.
    final List<OutboxOperationDraft> operations = <OutboxOperationDraft>[
      _op(
        entityType: 'workout_template',
        entityId: templateId.value,
        payload: FitnessReplicationPayload.template(template),
      ),
    ];

    for (final TemplateExerciseInput exercise in input.exercises) {
      final TemplateExercise child = TemplateExercise(
        id: TemplateExerciseId(idGenerator.uuidV7()),
        templateId: templateId,
        name: exercise.name,
        rank: exercise.rank,
        targetSets: exercise.targetSets,
        targetReps: exercise.targetReps,
        notes: exercise.notes,
      );
      await repo.insertTemplateExercise(
        child,
        profileId: profileId.value,
        nowUtc: now,
      );
      operations.add(
        _op(
          entityType: 'template_exercise',
          entityId: child.id.value,
          payload: FitnessReplicationPayload.templateExercise(child),
        ),
      );
    }

    return _write(
      resultCode: 'workout_template_created',
      resultPayload:
          '{"template_id":"${templateId.value}",'
          '"exercises":${input.exercises.length}}',
      entityType: 'workout_template',
      entityId: templateId.value,
      eventType: 'workout_template_created',
      operations: operations,
    );
  }

  Future<SemanticWrite> _logSessionBody(
    TransactionSession session,
    ProfileId profileId,
    WorkoutSessionId sessionId,
    LogWorkoutSessionInput input,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    final int now = _now;

    if (input.title.trim().isEmpty) {
      throw const _Validation('fitness.title_required');
    }
    if (input.endedAtUtc != null && input.endedAtUtc! < input.startedAtUtc) {
      throw const _Validation('fitness.end_before_start');
    }
    if (input.templateId != null) {
      final WorkoutTemplate? template = await repo.findTemplate(
        profileId.value,
        input.templateId!,
      );
      if (template == null) {
        throw _Validation(
          'fitness.template_not_found',
          cause: input.templateId,
        );
      }
    }

    final WorkoutSession workout = WorkoutSession(
      id: sessionId,
      lifeAreaId: LifeAreaId(input.lifeAreaId),
      title: input.title,
      templateId: input.templateId == null
          ? null
          : WorkoutTemplateId(input.templateId!),
      startedAtUtc: input.startedAtUtc,
      endedAtUtc: input.endedAtUtc,
      durationSec: input.durationSec,
      noteId: input.noteId,
      revision: 1,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insertSession(workout, profileId: profileId.value);

    // Parent-before-child: session, then each exercise log, then its set logs.
    final List<OutboxOperationDraft> operations = <OutboxOperationDraft>[
      _op(
        entityType: 'workout_session',
        entityId: sessionId.value,
        payload: FitnessReplicationPayload.session(workout),
      ),
    ];

    int totalSets = 0;
    for (final ExerciseLogInput exercise in input.exercises) {
      final ExerciseLogId exerciseLogId = ExerciseLogId(idGenerator.uuidV7());
      final ExerciseLog log = ExerciseLog(
        id: exerciseLogId,
        workoutId: sessionId,
        name: exercise.name,
        rank: exercise.rank,
        notes: exercise.notes,
      );
      await repo.insertExerciseLog(
        log,
        profileId: profileId.value,
        nowUtc: now,
      );
      operations.add(
        _op(
          entityType: 'exercise_log',
          entityId: exerciseLogId.value,
          payload: FitnessReplicationPayload.exerciseLog(log),
        ),
      );
      for (final SetLogInput set in exercise.sets) {
        final SetLog setLog = SetLog(
          id: SetLogId(idGenerator.uuidV7()),
          exerciseLogId: exerciseLogId,
          rank: set.rank,
          reps: set.reps,
          weight: _measure(set.weightValue, set.weightUnit, 'weight'),
          durationSec: set.durationSec,
          distance: _measure(set.distanceValue, set.distanceUnit, 'distance'),
          completedAtUtc: set.completedAtUtc,
        );
        await repo.insertSetLog(
          setLog,
          profileId: profileId.value,
          nowUtc: now,
        );
        operations.add(
          _op(
            entityType: 'set_log',
            entityId: setLog.id.value,
            payload: FitnessReplicationPayload.setLog(setLog),
          ),
        );
        totalSets += 1;
      }
    }

    return _write(
      resultCode: 'workout_session_logged',
      resultPayload:
          '{"session_id":"${sessionId.value}",'
          '"exercises":${input.exercises.length},"sets":$totalSets}',
      entityType: 'workout_session',
      entityId: sessionId.value,
      eventType: 'workout_session_logged',
      operations: operations,
      // A logged session is the canonical, addressable workout record, so it
      // joins the unified search index in the same semantic transaction
      // (R-SEARCH-001, task 10.5). The marker encodes the `workout` entity type
      // so the projector registry routes it to the workout projector; a bare id
      // could not be routed and would strand the marker (design.md §14).
      searchMarkers: <DirtyProjectionDraft>[
        DirtyProjectionDraft(
          projection: SearchDirtyKey.projection,
          projectionKey: SearchDirtyKey.encode(
            WorkoutSearchProjector.kind,
            sessionId.value,
          ),
        ),
      ],
    );
  }

  Future<SemanticWrite> _recordMeasurementBody(
    TransactionSession session,
    ProfileId profileId,
    BodyMeasurementId measurementId,
    RecordBodyMeasurementInput input,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    final int now = _now;

    final MeasuredQuantity value = _measure(input.value, input.unit, 'weight')!;
    if (value.dimension != 'mass') {
      throw _Validation('fitness.unit_not_mass', cause: input.unit);
    }

    final BodyMeasurement measurement = BodyMeasurement(
      id: measurementId,
      lifeAreaId: LifeAreaId(input.lifeAreaId),
      kind: BodyMeasurementKind.weight,
      value: value,
      measuredAtUtc: input.measuredAtUtc,
      note: input.note,
      revision: 1,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insertMeasurement(measurement, profileId: profileId.value);

    return _write(
      resultCode: 'body_measurement_recorded',
      resultPayload:
          '{"measurement_id":"${measurementId.value}",'
          '"canonical":${value.canonicalValue}}',
      entityType: 'body_measurement',
      entityId: measurementId.value,
      eventType: 'body_measurement_recorded',
      operations: <OutboxOperationDraft>[
        _op(
          entityType: 'body_measurement',
          entityId: measurementId.value,
          payload: FitnessReplicationPayload.measurement(measurement),
        ),
      ],
    );
  }

  Future<SemanticWrite> _logWaterEventBody(
    TransactionSession session,
    ProfileId profileId,
    WaterEventId eventId,
    LogWaterEventInput input,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    final int now = _now;

    final MeasuredQuantity amount = _measure(input.value, input.unit, 'water')!;
    if (amount.dimension != 'volume') {
      throw _Validation('fitness.unit_not_volume', cause: input.unit);
    }

    final WaterEvent event = WaterEvent(
      id: eventId,
      lifeAreaId: LifeAreaId(input.lifeAreaId),
      amount: amount,
      occurredAtUtc: input.occurredAtUtc,
      note: input.note,
      revision: 1,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insertWaterEvent(event, profileId: profileId.value);

    return _write(
      resultCode: 'water_event_logged',
      resultPayload:
          '{"event_id":"${eventId.value}",'
          '"canonical":${amount.canonicalValue}}',
      entityType: 'water_event',
      entityId: eventId.value,
      eventType: 'water_event_logged',
      operations: <OutboxOperationDraft>[
        _op(
          entityType: 'water_event',
          entityId: eventId.value,
          payload: FitnessReplicationPayload.waterEvent(event),
        ),
      ],
    );
  }

  // ---- helpers ------------------------------------------------------------

  /// Builds a [MeasuredQuantity] from an entered value/unit pair, rejecting a
  /// half-specified measurement or an invalid unit/value. Returns null when the
  /// measurement is fully absent.
  MeasuredQuantity? _measure(num? value, String? unit, String field) {
    if (value == null && unit == null) {
      return null;
    }
    if (value == null || unit == null) {
      throw _Validation('fitness.incomplete_measurement', cause: field);
    }
    try {
      return MeasuredQuantity.of(value, unit);
    } on UnitConversionError catch (e) {
      throw _Validation('fitness.invalid_measurement', cause: e.code);
    }
  }

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = FitnessCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: FitnessCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.fitness.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  /// Builds one insert outbox operation carrying the manifest-replicated
  /// payload for a fitness entity. The payload is canonicalized so the same
  /// logical row always produces the same bytes.
  OutboxOperationDraft _op({
    required String entityType,
    required String entityId,
    required Map<String, Object?> payload,
  }) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: entityType,
    entityId: entityId,
    opKind: 'insert',
    payload: FitnessCanonicalRequest.encode(payload),
  );

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required String entityType,
    required String entityId,
    required String eventType,
    List<OutboxOperationDraft> operations = const <OutboxOperationDraft>[],
    List<DirtyProjectionDraft> searchMarkers = const <DirtyProjectionDraft>[],
  }) {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: eventType,
          entityType: entityType,
          entityId: entityId,
          payloadVersion: _payloadVersion,
        ),
      ],
      // Today keeps a lightweight marker keyed by entity id; workout sessions
      // additionally emit a unified-search marker so the workout projector runs
      // in the same semantic transaction (R-SEARCH-001, task 10.5).
      dirtyProjections: <DirtyProjectionDraft>[
        DirtyProjectionDraft(projection: 'today', projectionKey: entityId),
        ...searchMarkers,
      ],
      // A fitness command is sync-eligible: its ordered, parent-before-child
      // operations form one semantic group committed atomically with the domain
      // rows and its immutable journal entry (task 12.1, R-SYNC-002). The
      // snapshot epoch is 0 pre-link; the sync waves stamp the live epoch.
      outboxGroup: operations.isEmpty
          ? null
          : OutboxGroupDraft(
              groupId: idGenerator.uuidV7(),
              snapshotEpoch: 0,
              operations: operations,
            ),
    );
  }
}
