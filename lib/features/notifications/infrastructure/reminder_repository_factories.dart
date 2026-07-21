import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repositories.dart';

/// Transaction-scoped repository factories contributed by the notifications
/// feature. The composition root merges these into the [DriftUnitOfWork] so a
/// reminder command body can resolve a [ReminderWriteRepository] bound to the
/// active transaction (design §5/§6).
final Map<Type, RepositoryFactory> reminderRepositoryFactories =
    <Type, RepositoryFactory>{
      ReminderWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              ReminderWriteRepository(db, scope),
    };
