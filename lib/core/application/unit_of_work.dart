enum WriteOrigin {
  localCommand,
  remoteApply,
  bootstrapRebase,
  restore,
  migration,
}

/// Transaction-scoped repository lookup. Implementations must reject use after
/// their owning transaction completes.
abstract interface class RepositorySet {
  T resolve<T extends Object>();
}

abstract interface class TransactionSession {
  RepositorySet get repositories;

  WriteOrigin get origin;

  int get commitSeq;
}

typedef TransactionAction<T> = Future<T> Function(TransactionSession session);

abstract interface class UnitOfWork {
  Future<T> transaction<T>(
    TransactionAction<T> action, {
    WriteOrigin origin = WriteOrigin.localCommand,
  });
}
