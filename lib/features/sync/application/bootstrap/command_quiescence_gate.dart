/// A reference [MaintenanceGate] that closes command admission, drives
/// quiescence, and produces a retryable maintenance failure for any command
/// admitted while a bootstrap is running (R-SYNC-006, design.md §12).
///
/// This is pure application logic: it holds the admission flag and delegates
/// the two blocking steps — awaiting active local transactions and
/// stopping/settling sync workers — to injected callbacks so a real
/// composition can wire them to the `DatabaseRuntime` transaction scheduler and
/// the sync worker pool without this class importing infrastructure.
library;

// Named constructor parameters use public names bound to private fields; the
// initializing-formal form would leak underscored parameter names into the API.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';

/// A hook the gate awaits during quiescence. Defaults to a completed future.
typedef QuiescenceHook = Future<void> Function();

Future<void> _noop() async {}

/// The stable code and message key for a command rejected because a bootstrap
/// (or other maintenance) is in progress. It is retryable: the caller retries
/// after the gate reopens rather than dropping the command.
const String kMaintenanceInProgressCode = 'sync.maintenance_in_progress';

/// The reference maintenance gate.
final class CommandQuiescenceGate implements MaintenanceGate {
  CommandQuiescenceGate({
    QuiescenceHook awaitTransactions = _noop,
    QuiescenceHook settleWorkers = _noop,
  }) : _awaitTransactions = awaitTransactions,
       _settleWorkers = settleWorkers;

  final QuiescenceHook _awaitTransactions;
  final QuiescenceHook _settleWorkers;

  bool _admitting = true;
  bool _transactionsAwaited = false;
  bool _workersSettled = false;

  @override
  bool get isAdmitting => _admitting;

  /// Whether active transactions have been awaited since the gate last closed.
  bool get transactionsAwaited => _transactionsAwaited;

  /// Whether sync workers have been settled since the gate last closed.
  bool get workersSettled => _workersSettled;

  @override
  Result<void> admit() {
    if (_admitting) {
      return const Success<void>(null);
    }
    return const Failed<void>(
      Failure(
        kind: FailureKind.maintenanceLocked,
        code: kMaintenanceInProgressCode,
        safeMessageKey: 'error.sync.maintenance_in_progress',
        retryable: true,
      ),
    );
  }

  @override
  Future<void> closeAdmission() async {
    _admitting = false;
    _transactionsAwaited = false;
    _workersSettled = false;
  }

  @override
  Future<void> awaitActiveTransactions() async {
    await _awaitTransactions();
    _transactionsAwaited = true;
  }

  @override
  Future<void> settleSyncWorkers() async {
    await _settleWorkers();
    _workersSettled = true;
  }

  @override
  Future<void> reopenAdmission() async {
    _admitting = true;
  }
}
