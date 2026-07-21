import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';

abstract interface class TransactionalParticipant {
  Object snapshot();
  void restore(Object snapshot);
}

final class TransactionalTestStore implements TransactionalParticipant {
  final Map<String, Object?> _values = <String, Object?>{};

  Object? operator [](String key) => _values[key];

  void operator []=(String key, Object? value) {
    _values[key] = value;
  }

  Map<String, Object?> get values => Map<String, Object?>.unmodifiable(_values);

  @override
  Object snapshot() => Map<String, Object?>.of(_values);

  @override
  void restore(Object snapshot) {
    _values
      ..clear()
      ..addAll(snapshot as Map<String, Object?>);
  }
}

final class HarnessRepositorySet implements RepositorySet {
  HarnessRepositorySet(Map<Type, Object> repositories)
    : _repositories = Map<Type, Object>.unmodifiable(repositories);

  final Map<Type, Object> _repositories;
  bool _active = true;

  @override
  T resolve<T extends Object>() {
    if (!_active) {
      throw StateError('Transaction-scoped repositories are no longer active.');
    }
    final Object? repository = _repositories[T];
    if (repository is! T) {
      throw StateError('No repository registered for $T.');
    }
    return repository;
  }

  void close() {
    _active = false;
  }
}

final class HarnessTransactionSession implements TransactionSession {
  const HarnessTransactionSession({
    required this.repositories,
    required this.origin,
    required this.commitSeq,
  });

  @override
  final HarnessRepositorySet repositories;
  @override
  final WriteOrigin origin;
  @override
  final int commitSeq;
}

final class FakeUnitOfWork implements UnitOfWork {
  FakeUnitOfWork({
    required Map<Type, Object> repositories,
    Iterable<TransactionalParticipant> participants =
        const <TransactionalParticipant>[],
  }) : _repositories = Map<Type, Object>.of(repositories),
       _participants = List<TransactionalParticipant>.of(participants);

  final Map<Type, Object> _repositories;
  final List<TransactionalParticipant> _participants;
  bool _inTransaction = false;
  int _commitSeq = 0;
  Exception? _nextCommitFailure;

  int get committedSequence => _commitSeq;

  /// Injects a failure after the transaction body but before commit.
  ///
  /// This models disk-full and equivalent commit-boundary failures while still
  /// exercising participant rollback.
  void failNextCommit(Exception failure) {
    if (_nextCommitFailure != null) {
      throw StateError('A commit failure is already queued.');
    }
    _nextCommitFailure = failure;
  }

  @override
  Future<T> transaction<T>(
    TransactionAction<T> action, {
    WriteOrigin origin = WriteOrigin.localCommand,
  }) async {
    if (_inTransaction) {
      throw StateError(
        'Nested transactions are not supported by this harness.',
      );
    }
    _inTransaction = true;
    final List<Object> snapshots = _participants
        .map((TransactionalParticipant participant) => participant.snapshot())
        .toList();
    final HarnessRepositorySet repositories = HarnessRepositorySet(
      _repositories,
    );
    final HarnessTransactionSession session = HarnessTransactionSession(
      repositories: repositories,
      origin: origin,
      commitSeq: _commitSeq + 1,
    );
    try {
      final T result = await action(session);
      final Exception? commitFailure = _nextCommitFailure;
      if (commitFailure != null) {
        _nextCommitFailure = null;
        throw commitFailure;
      }
      _commitSeq += 1;
      return result;
    } on Object {
      for (int index = 0; index < _participants.length; index += 1) {
        _participants[index].restore(snapshots[index]);
      }
      rethrow;
    } finally {
      repositories.close();
      _inTransaction = false;
    }
  }
}

final class FakeDatabaseRuntime implements DatabaseRuntime {
  FakeDatabaseRuntime({
    required this.activeGeneration,
    required this.unitOfWork,
  });

  @override
  final DatabaseGeneration activeGeneration;
  @override
  final UnitOfWork unitOfWork;
  DatabaseRuntimeState _state = DatabaseRuntimeState.ready;

  @override
  DatabaseRuntimeState get state => _state;

  void enterMaintenance() {
    _requireOpen();
    _state = DatabaseRuntimeState.maintenance;
  }

  void resume() {
    _requireOpen();
    _state = DatabaseRuntimeState.ready;
  }

  void requireRecovery() {
    _requireOpen();
    _state = DatabaseRuntimeState.recoveryRequired;
  }

  @override
  Future<void> dispose() async {
    if (_state == DatabaseRuntimeState.closed) {
      return;
    }
    _state = DatabaseRuntimeState.closing;
    _state = DatabaseRuntimeState.closed;
  }

  void _requireOpen() {
    if (_state == DatabaseRuntimeState.closing ||
        _state == DatabaseRuntimeState.closed) {
      throw StateError('Database runtime is closed.');
    }
  }
}

final class FakeDatabaseRuntimeFactory implements DatabaseRuntimeFactory {
  FakeDatabaseRuntimeFactory(this._create);

  final FakeDatabaseRuntime Function() _create;
  int openCount = 0;

  @override
  Future<FakeDatabaseRuntime> open() async {
    openCount += 1;
    return _create();
  }
}
