import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/goals/infrastructure/goal_write_repository.dart';

/// Transaction-scoped repository factories contributed by the goals feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [GoalWriteRepository] (goals, milestones, tags)
/// bound to the active transaction (design.md §5/§6). Registering factories
/// here keeps the goals DAO owned by the goals feature.
final Map<Type, RepositoryFactory> goalRepositoryFactories =
    <Type, RepositoryFactory>{
      GoalWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
          GoalWriteRepository(db, scope),
    };

/// The trashable entity descriptor for goals (R-GEN-003, R-GOAL-007). The
/// composition root adds this to the shared `TrashRegistry` so goal trash /
/// restore / purge reuse the deletion kernel. Goals are sync-eligible, so
/// ordinary deletion produces a replicated tombstone. Archival is a distinct,
/// non-destructive state that preserves history and links (R-GOAL-007).
const String goalTrashableEntityType = 'goal';
