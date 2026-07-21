import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/areas/infrastructure/life_area_write_repository.dart';

/// Transaction-scoped repository factories contributed by the areas feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// Life Area command body can resolve a [LifeAreaWriteRepository] bound to the
/// active transaction (design.md §5/§6). Registering factories here — rather
/// than in the app defaults — keeps the `life_areas` DAO owned by the areas
/// feature.
final Map<Type, RepositoryFactory> areaRepositoryFactories =
    <Type, RepositoryFactory>{
      LifeAreaWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              LifeAreaWriteRepository(db, scope),
    };
