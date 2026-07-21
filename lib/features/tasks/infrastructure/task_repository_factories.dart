import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_write_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_write_repository.dart';

/// Transaction-scoped repository factories contributed by the tasks feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [TaskWriteRepository] or
/// [RecurrenceWriteRepository] bound to the active transaction (design.md
/// §5/§6). Registering factories here — rather than in the app defaults — keeps
/// the tasks DAO owned by the tasks feature.
final Map<Type, RepositoryFactory> taskRepositoryFactories =
    <Type, RepositoryFactory>{
      TaskWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
          TaskWriteRepository(db, scope),
      RecurrenceWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              RecurrenceWriteRepository(db, scope),
    };
