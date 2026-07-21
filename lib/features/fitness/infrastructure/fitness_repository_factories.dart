import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/fitness/infrastructure/fitness_write_repository.dart';

/// Transaction-scoped repository factories contributed by the fitness feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [FitnessWriteRepository] bound to the active
/// transaction (design.md §5/§6). Registering factories here — rather than in
/// the app defaults — keeps the fitness DAO owned by the fitness feature.
final Map<Type, RepositoryFactory> fitnessRepositoryFactories =
    <Type, RepositoryFactory>{
      FitnessWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              FitnessWriteRepository(db, scope),
    };

/// The trashable entity types for the top-level fitness owners (R-GEN-003,
/// R-FIT-001, R-FIT-002, R-FIT-003). The composition root adds these to the
/// shared `TrashRegistry` so fitness trash / restore / purge reuse the deletion
/// kernel. They are sync-eligible (task 12.1), so ordinary deletion produces a
/// replicated tombstone (data-model.md §3). Their inherited-area children
/// (template exercises, exercise logs, set logs) carry no soft-delete column
/// and are removed with their parent, so they are not independently trashable.
const String workoutTemplateTrashableEntityType = 'workout_template';
const String workoutSessionTrashableEntityType = 'workout_session';
const String bodyMeasurementTrashableEntityType = 'body_measurement';
const String waterEventTrashableEntityType = 'water_event';

/// The fitness soft-deletable aggregates and their backing tables. The
/// composition root merges these into the shared `TrashRegistry`.
List<TrashableEntity> fitnessTrashableEntities() => <TrashableEntity>[
  TrashableEntity(
    entityType: workoutTemplateTrashableEntityType,
    tableName: 'workout_templates',
  ),
  TrashableEntity(
    entityType: workoutSessionTrashableEntityType,
    tableName: 'workout_sessions',
  ),
  TrashableEntity(
    entityType: bodyMeasurementTrashableEntityType,
    tableName: 'body_measurements',
  ),
  TrashableEntity(
    entityType: waterEventTrashableEntityType,
    tableName: 'water_events',
  ),
];
