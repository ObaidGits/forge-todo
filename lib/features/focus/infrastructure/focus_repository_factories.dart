import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/focus/infrastructure/focus_write_repository.dart';

/// Transaction-scoped repository factories contributed by the focus feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// focus command body can resolve a [FocusWriteRepository] bound to the active
/// transaction (design.md §5/§6). Registering factories here keeps the focus
/// DAO owned by the focus feature.
final Map<Type, RepositoryFactory> focusRepositoryFactories =
    <Type, RepositoryFactory>{
      FocusWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
          FocusWriteRepository(db, scope),
    };
