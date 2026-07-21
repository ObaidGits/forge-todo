import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/infrastructure/fitness_replication_payload.dart';
import 'package:forge/features/fitness/infrastructure/fitness_write_repository.dart';
import 'package:forge/features/sync/application/remote_applier.dart';

/// Typed remote appliers for the replicated fitness records (task 12.1;
/// R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002, R-SYNC-003, R-SYNC-004,
/// NFR-REL-003).
///
/// Each applier owns exactly one fitness entity type and applies one pulled
/// change within the shared pull transaction by upserting the row (insert or
/// patch) or removing/soft-deleting it (tombstone). Every applier is
/// idempotent: an upsert keyed on the row's primary key and a tombstone that is
/// a no-op when re-applied make replaying the same change safe.
///
/// Parent-before-child ordering is enforced two ways: the outbox projector
/// emits a group in `template → template_exercise` and
/// `session → exercise_log → set_log` order, the server change feed preserves
/// that order, and [fitnessRemoteAppliers] registers the appliers in the same
/// order so a page's changes are routed to a child applier only after its
/// parent applier has run (design.md §8/§9, R-SYNC-004). The appliers perform
/// no network/file/plugin work inside the transaction; the derived canonical
/// `*_scaled` amounts are recomputed from the entered value/unit by the shared
/// [FitnessReplicationPayload] codec.

/// A tombstone soft-delete marker for a top-level fitness owner. The server
/// `server_seq` is used because it is assigned once by the server and is
/// identical on every device and on every re-apply, so the marker is
/// deterministic and the applier stays idempotent.
int _tombstoneMarker(RemoteChange change) => change.serverSeq.value;

bool _isDelete(RemoteChange change) =>
    change.tombstone || change.kind == SyncOperationKind.delete;

FitnessWriteRepository _repo(TransactionSession tx) =>
    tx.repositories.resolve<FitnessWriteRepository>();

/// Applies replicated `workout_template` changes.
final class WorkoutTemplateApplier implements RemoteApplier {
  const WorkoutTemplateApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'workout_template';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(tx).tombstoneTemplate(
        change.entityId,
        profileId: profileId.value,
        deletedAtUtc: _tombstoneMarker(change),
      );
      return;
    }
    await _repo(tx).upsertTemplate(
      FitnessReplicationPayload.templateFrom(change.payload),
      profileId: profileId.value,
    );
  }
}

/// Applies replicated `template_exercise` changes (child of a template).
final class TemplateExerciseApplier implements RemoteApplier {
  const TemplateExerciseApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'template_exercise';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(
        tx,
      ).deleteTemplateExercise(change.entityId, profileId: profileId.value);
      return;
    }
    await _repo(tx).upsertTemplateExercise(
      FitnessReplicationPayload.templateExerciseFrom(change.payload),
      profileId: profileId.value,
      nowUtc: _tombstoneMarker(change),
    );
  }
}

/// Applies replicated `workout_session` changes.
final class WorkoutSessionApplier implements RemoteApplier {
  const WorkoutSessionApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'workout_session';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(tx).tombstoneSession(
        change.entityId,
        profileId: profileId.value,
        deletedAtUtc: _tombstoneMarker(change),
      );
      return;
    }
    await _repo(tx).upsertSession(
      FitnessReplicationPayload.sessionFrom(change.payload),
      profileId: profileId.value,
    );
  }
}

/// Applies replicated `exercise_log` changes (child of a session).
final class ExerciseLogApplier implements RemoteApplier {
  const ExerciseLogApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'exercise_log';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(
        tx,
      ).deleteExerciseLog(change.entityId, profileId: profileId.value);
      return;
    }
    await _repo(tx).upsertExerciseLog(
      FitnessReplicationPayload.exerciseLogFrom(change.payload),
      profileId: profileId.value,
      nowUtc: _tombstoneMarker(change),
    );
  }
}

/// Applies replicated `set_log` changes (child of an exercise log).
final class SetLogApplier implements RemoteApplier {
  const SetLogApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'set_log';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(tx).deleteSetLog(change.entityId, profileId: profileId.value);
      return;
    }
    await _repo(tx).upsertSetLog(
      FitnessReplicationPayload.setLogFrom(change.payload),
      profileId: profileId.value,
      nowUtc: _tombstoneMarker(change),
    );
  }
}

/// Applies replicated `body_measurement` changes.
final class BodyMeasurementApplier implements RemoteApplier {
  const BodyMeasurementApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'body_measurement';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(tx).tombstoneMeasurement(
        change.entityId,
        profileId: profileId.value,
        deletedAtUtc: _tombstoneMarker(change),
      );
      return;
    }
    await _repo(tx).upsertMeasurement(
      FitnessReplicationPayload.measurementFrom(change.payload),
      profileId: profileId.value,
    );
  }
}

/// Applies replicated `water_event` changes. Water EVENTS replicate as ordinary
/// fitness records; only the disabled-by-default enable preference is
/// device-local (R-FIT-003), so a device that never enabled water tracking
/// still converges on any water events synced from another device.
final class WaterEventApplier implements RemoteApplier {
  const WaterEventApplier(this.profileId);

  final ProfileId profileId;

  @override
  String get entityType => 'water_event';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (_isDelete(change)) {
      await _repo(tx).tombstoneWaterEvent(
        change.entityId,
        profileId: profileId.value,
        deletedAtUtc: _tombstoneMarker(change),
      );
      return;
    }
    await _repo(tx).upsertWaterEvent(
      FitnessReplicationPayload.waterEventFrom(change.payload),
      profileId: profileId.value,
    );
  }
}

/// The fitness feature's typed remote appliers, in parent-before-child
/// registration order. The composition root merges these into the shared
/// [RemoteApplierRegistry] so a pull page routes each fitness change to its
/// owning applier (design.md §8/§9).
List<RemoteApplier> fitnessRemoteAppliers(ProfileId profileId) =>
    <RemoteApplier>[
      WorkoutTemplateApplier(profileId),
      TemplateExerciseApplier(profileId),
      WorkoutSessionApplier(profileId),
      ExerciseLogApplier(profileId),
      SetLogApplier(profileId),
      BodyMeasurementApplier(profileId),
      WaterEventApplier(profileId),
    ];
