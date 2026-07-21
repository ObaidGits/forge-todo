import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/learning/infrastructure/learning_write_repository.dart';

/// Transaction-scoped repository factories contributed by the learning feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// learning command body — and the registered [LearningSearchProjector] — can
/// resolve a [LearningWriteRepository] bound to the active transaction
/// (design.md §5/§6). Registering factories here keeps the learning DAO owned by
/// the learning feature.
final Map<Type, RepositoryFactory> learningRepositoryFactories =
    <Type, RepositoryFactory>{
      LearningWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              LearningWriteRepository(db, scope),
    };
