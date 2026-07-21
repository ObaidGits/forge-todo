/// Liveness token shared by a transaction session and every repository it
/// hands out.
///
/// design.md §5/§16 forbid using a repository outside the transaction that
/// created it. When the transaction completes (commit or rollback) the scope is
/// closed; any subsequent repository call throws [TransactionClosedError],
/// even through a reference captured and leaked past the boundary.
final class TransactionScope {
  bool _active = true;

  bool get isActive => _active;

  /// Throws if the owning transaction has completed.
  void ensureActive() {
    if (!_active) {
      throw TransactionClosedError();
    }
  }

  void close() {
    _active = false;
  }
}

/// Thrown when a transaction-scoped repository is used after its transaction
/// has committed or rolled back.
final class TransactionClosedError extends StateError {
  TransactionClosedError()
    : super(
        'Transaction-scoped repository used after its transaction completed.',
      );
}
