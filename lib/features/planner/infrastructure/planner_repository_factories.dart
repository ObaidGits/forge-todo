import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/planner/infrastructure/planner_write_repository.dart';

/// Transaction-scoped repository factories contributed by the planner feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// planner command body can resolve a [PlannerWriteRepository] bound to the
/// active transaction (design.md §5/§6). Registering factories here — rather
/// than in the app defaults — keeps the planner DAO owned by the planner
/// feature.
final Map<Type, RepositoryFactory> plannerRepositoryFactories =
    <Type, RepositoryFactory>{
      PlannerWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              PlannerWriteRepository(db, scope),
    };
