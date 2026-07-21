import 'package:forge/core/database/runtime.dart';

/// DB-neutral connection to a single generation store used during migration.
///
/// The concrete implementation is kept behind this port (mirroring
/// [EncryptedStoreOpener] in `encrypted_store.dart`) so the migration engine
/// depends only on SQL execution, never on a cipher- or isolate-specific API.
/// Production wires an encrypted Drift isolate; tests wire a native SQLite
/// build with real FTS5.
abstract interface class MigrationConnection implements AsyncResource {
  /// Executes a single statement with optional positional arguments.
  Future<void> execute(String sql, [List<Object?> arguments]);

  /// Runs a query and materialises every row as a column→value map.
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments,
  ]);

  /// Runs [action] inside one database transaction.
  ///
  /// The implementation MUST commit when [action] returns and roll back when it
  /// throws, so a crash between statements can never leave a partially applied
  /// batch (data-model §5, NFR-REL-002).
  Future<T> transaction<T>(Future<T> Function() action);
}

/// Opens a [MigrationConnection] for a generation directory.
///
/// [createIfMissing] provisions a brand-new empty store (used when building a
/// shadow generation); when false the directory must already contain a store.
abstract interface class MigrationConnectionOpener {
  Future<MigrationConnection> open(
    String generationDirectory, {
    required bool createIfMissing,
  });
}

/// Convenience helpers layered on the minimal [MigrationConnection] contract.
extension MigrationConnectionQueries on MigrationConnection {
  /// Returns the single integer produced by a scalar aggregate query.
  Future<int> scalarInt(
    String sql, [
    List<Object?> arguments = const <Object?>[],
  ]) async {
    final List<Map<String, Object?>> rows = await select(sql, arguments);
    if (rows.isEmpty) {
      return 0;
    }
    final Object? value = rows.first.values.first;
    if (value is int) {
      return value;
    }
    if (value is BigInt) {
      return value.toInt();
    }
    throw MigrationConnectionException(
      'Expected an integer scalar, got $value.',
    );
  }

  /// Returns the row count of [table].
  Future<int> countRows(String table) =>
      scalarInt('SELECT COUNT(*) AS n FROM "$table"');

  /// Names of every user table in the store, excluding SQLite internals and
  /// FTS5 shadow tables.
  Future<List<String>> userTables() async {
    final List<Map<String, Object?>> rows = await select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows
        .map((Map<String, Object?> row) => row['name']! as String)
        .toList(growable: false);
  }
}

/// Raised when a migration connection cannot satisfy a request. Never triggers
/// a data reset; the migrator surfaces it and keeps the prior generation.
final class MigrationConnectionException implements Exception {
  const MigrationConnectionException(this.message);

  final String message;

  @override
  String toString() => 'MigrationConnectionException($message)';
}
