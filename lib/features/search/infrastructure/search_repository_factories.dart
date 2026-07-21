import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/search/infrastructure/search_write_repository.dart';

/// Transaction-scoped repository factories contributed by the search feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so the
/// in-transaction projection coordinator, the startup reconciler and the source
/// rebuild path can resolve a [SearchWriteRepository] bound to the active
/// transaction (design.md §5/§6). Search index maintenance lives behind the
/// search feature boundary.
final Map<Type, RepositoryFactory> searchRepositoryFactories =
    <Type, RepositoryFactory>{
      SearchWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
          SearchWriteRepository(db, scope),
    };
