import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';

enum DatabaseRuntimeState {
  stopped,
  starting,
  ready,
  maintenance,
  recoveryRequired,
  closing,
  closed,
}

/// A resource whose asynchronous shutdown must be awaited by its owner.
abstract interface class AsyncResource {
  Future<void> dispose();
}

final class DatabaseGeneration {
  const DatabaseGeneration({required this.id, required this.schemaVersion});

  final GenerationId id;
  final int schemaVersion;
}

/// DB-neutral process runtime contract. Drift and platform lock types remain in
/// infrastructure implementations.
abstract interface class DatabaseRuntime implements AsyncResource {
  DatabaseRuntimeState get state;

  DatabaseGeneration get activeGeneration;

  UnitOfWork get unitOfWork;
}

abstract interface class DatabaseRuntimeFactory {
  Future<DatabaseRuntime> open();
}
