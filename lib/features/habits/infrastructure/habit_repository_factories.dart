import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/habits/infrastructure/habit_write_repository.dart';

/// Transaction-scoped repository factories contributed by the habits feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [HabitWriteRepository] bound to the active
/// transaction (design.md §5/§6). Registering factories here — rather than in
/// the app defaults — keeps the habits DAO owned by the habits feature.
final Map<Type, RepositoryFactory> habitRepositoryFactories =
    <Type, RepositoryFactory>{
      HabitWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
          HabitWriteRepository(db, scope),
    };
