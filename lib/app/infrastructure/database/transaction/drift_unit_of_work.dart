import 'dart:async';

import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_guard.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/application/unit_of_work.dart';

/// Builds a transaction-scoped repository bound to [db] and [scope].
typedef RepositoryFactory =
    Object Function(ForgeSchemaDatabase db, TransactionScope scope);

/// Transaction-scoped repository lookup for a Drift session.
///
/// Repositories are lazily created and cached per transaction. Every resolve
/// checks the shared [TransactionScope], so use after the transaction completes
/// throws [TransactionClosedError] (design.md §5).
final class DriftRepositorySet implements RepositorySet {
  DriftRepositorySet(this._factories, this._db, this._scope);

  final Map<Type, RepositoryFactory> _factories;
  final ForgeSchemaDatabase _db;
  final TransactionScope _scope;
  final Map<Type, Object> _cache = <Type, Object>{};

  @override
  T resolve<T extends Object>() {
    _scope.ensureActive();
    final Object? cached = _cache[T];
    if (cached is T) {
      return cached;
    }
    final RepositoryFactory? factory = _factories[T];
    if (factory == null) {
      throw StateError('No repository registered for $T.');
    }
    final Object repository = factory(_db, _scope);
    if (repository is! T) {
      throw StateError(
        'Repository factory for $T produced ${repository.runtimeType}.',
      );
    }
    _cache[T] = repository;
    return repository;
  }
}

/// A Drift-backed transaction session (design.md §5).
final class DriftTransactionSession implements TransactionSession {
  DriftTransactionSession({
    required this.repositories,
    required this.origin,
    required this.commitSeq,
  });

  @override
  final DriftRepositorySet repositories;

  @override
  final WriteOrigin origin;

  @override
  final int commitSeq;
}

/// Production [UnitOfWork] over the encrypted Drift database.
///
/// * One outer [transaction] runs the action inside a real Drift transaction.
/// * Nested [transaction] calls join the active session; they never open an
///   implicit savepoint. A nested call requesting a different [WriteOrigin]
///   fails deterministically (design.md §5).
/// * The action runs inside [runInTransactionGuard], which forbids timers and
///   other unbounded time-based awaits while the write lock is held.
final class DriftUnitOfWork implements UnitOfWork {
  DriftUnitOfWork(
    this._db, {
    required this.activeProfileResolver,
    Map<Type, RepositoryFactory>? repositoryFactories,
  }) : _factories = <Type, RepositoryFactory>{
         ..._defaultFactories,
         ...?repositoryFactories,
       };

  final ForgeSchemaDatabase _db;

  /// Resolves the id of the active local profile for commit-sequence peeking.
  final String Function() activeProfileResolver;

  final Map<Type, RepositoryFactory> _factories;

  static final Object _sessionKey = Object();

  static final Map<Type, RepositoryFactory>
  _defaultFactories = <Type, RepositoryFactory>{
    CommandReceiptRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        CommandReceiptRepository(db, s),
    CommitLogRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        CommitLogRepository(db, s),
    ActivityRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        ActivityRepository(db, s),
    ProjectionDirtyRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        ProjectionDirtyRepository(db, s),
    PendingCommandJournalRepository:
        (ForgeSchemaDatabase db, TransactionScope s) =>
            PendingCommandJournalRepository(db, s),
    OutboxRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        OutboxRepository(db, s),
    SyncConflictRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        SyncConflictRepository(db, s),
    SyncCursorRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        SyncCursorRepository(db, s),
    AppliedOperationRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        AppliedOperationRepository(db, s),
    TrashRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        TrashRepository(db, s),
    PurgeGuardRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        PurgeGuardRepository(db, s),
    FileJournalRepository: (ForgeSchemaDatabase db, TransactionScope s) =>
        FileJournalRepository(db, s),
  };

  @override
  Future<T> transaction<T>(
    TransactionAction<T> action, {
    WriteOrigin origin = WriteOrigin.localCommand,
  }) {
    final Object? current = Zone.current[_sessionKey];
    if (current is DriftTransactionSession) {
      // Nested call: join the existing session or fail deterministically. No
      // implicit savepoint is ever created.
      if (current.origin != origin) {
        throw StateError(
          'Nested transaction requested origin ${origin.name} inside an active '
          '${current.origin.name} transaction; savepoints are not implicit.',
        );
      }
      return Future<T>.sync(() => action(current));
    }

    return _db.transaction<T>(() async {
      final TransactionScope scope = TransactionScope();
      final int commitSeq = await CommitLogRepository(
        _db,
        scope,
      ).nextCommitSeq(activeProfileResolver());
      final DriftRepositorySet repositories = DriftRepositorySet(
        _factories,
        _db,
        scope,
      );
      final DriftTransactionSession session = DriftTransactionSession(
        repositories: repositories,
        origin: origin,
        commitSeq: commitSeq,
      );
      try {
        return await runZoned<Future<T>>(
          () => runInTransactionGuard<T>(() => action(session)),
          zoneValues: <Object?, Object?>{_sessionKey: session},
        );
      } finally {
        scope.close();
      }
    });
  }
}
