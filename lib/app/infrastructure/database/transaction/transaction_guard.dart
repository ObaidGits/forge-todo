import 'dart:async';

/// Raised when code inside a database transaction performs an operation that
/// design.md §5 forbids: network, filesystem, plugin calls, isolates, timers,
/// or unbounded awaits.
///
/// Timer creation (and therefore `Future.delayed` and other time-based waits)
/// is intercepted at runtime by [runInTransactionGuard]; filesystem, network,
/// plugin, and isolate usage are additionally rejected statically by the
/// architecture fitness gate (design.md §16).
final class ForbiddenInTransaction implements Exception {
  const ForbiddenInTransaction(this.operation);

  /// The forbidden operation that was attempted, e.g. `timer`.
  final String operation;

  @override
  String toString() =>
      'ForbiddenInTransaction: $operation is not allowed inside a database '
      'transaction (design.md §5).';
}

/// Runs [body] in a zone that forbids timers.
///
/// A database transaction must complete without waiting on wall-clock time.
/// Banning [Timer] creation deterministically rejects `Future.delayed`, polling
/// loops, and other unbounded time-based awaits that would hold the write lock
/// open. Microtask-based completion (ordinary `await` on already-scheduled
/// futures such as Drift query results) is unaffected.
Future<T> runInTransactionGuard<T>(Future<T> Function() body) {
  return runZoned<Future<T>>(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer:
          (
            Zone self,
            ZoneDelegate parent,
            Zone zone,
            Duration duration,
            void Function() callback,
          ) {
            throw const ForbiddenInTransaction('timer');
          },
      createPeriodicTimer:
          (
            Zone self,
            ZoneDelegate parent,
            Zone zone,
            Duration period,
            void Function(Timer timer) callback,
          ) {
            throw const ForbiddenInTransaction('periodic timer');
          },
    ),
  );
}
