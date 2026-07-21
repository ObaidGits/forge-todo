import 'dart:io';

import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:sqlite3/sqlite3.dart';

/// Real-SQLite [MigrationConnection] for migration tests.
///
/// Uses the native `sqlite3` build the app ships behind Drift, so migrations,
/// constraints, `PRAGMA` checks, and FTS5 behave exactly as in production —
/// only the cipher layer (ADR-0001) is absent.
final class Sqlite3MigrationConnection implements MigrationConnection {
  Sqlite3MigrationConnection(this._db);

  final Database _db;

  bool _disposed = false;

  @override
  Future<void> execute(
    String sql, [
    List<Object?> arguments = const <Object?>[],
  ]) async {
    if (arguments.isEmpty) {
      _db.execute(sql);
      return;
    }
    final PreparedStatement statement = _db.prepare(sql);
    try {
      statement.execute(arguments);
    } finally {
      statement.close();
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments = const <Object?>[],
  ]) async {
    final ResultSet result = arguments.isEmpty
        ? _db.select(sql)
        : _db.select(sql, arguments);
    final List<String> columns = result.columnNames;
    return result.rows
        .map((List<Object?> values) {
          final Map<String, Object?> row = <String, Object?>{};
          for (int i = 0; i < columns.length; i += 1) {
            row[columns[i]] = values[i];
          }
          return row;
        })
        .toList(growable: false);
  }

  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    _db.execute('BEGIN');
    try {
      final T result = await action();
      _db.execute('COMMIT');
      return result;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _db.close();
  }
}

/// Opens file-backed [Sqlite3MigrationConnection]s inside generation dirs.
final class Sqlite3MigrationConnectionOpener
    implements MigrationConnectionOpener {
  Sqlite3MigrationConnectionOpener({this.storeFileName = 'store.sqlite'});

  final String storeFileName;

  int openCount = 0;

  @override
  Future<MigrationConnection> open(
    String generationDirectory, {
    required bool createIfMissing,
  }) async {
    final Directory dir = Directory(generationDirectory);
    if (createIfMissing) {
      await dir.create(recursive: true);
    }
    final String path = '${dir.path}/$storeFileName';
    if (!createIfMissing && !File(path).existsSync()) {
      throw MigrationConnectionException('Store missing at $path.');
    }
    openCount += 1;
    final Database db = sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON');
    return Sqlite3MigrationConnection(db);
  }
}

/// Deterministic disk-space probe. Mutable so a test can shrink capacity.
final class FakeDiskSpaceProbe implements DiskSpaceProbe {
  FakeDiskSpaceProbe(this.available);

  int available;
  String? lastPath;

  @override
  Future<int> availableBytes(String path) async {
    lastPath = path;
    return available;
  }
}

/// Whether the bundled SQLite build supports FTS5.
///
/// Non-quarantinable migration/restore integrity suites (testing.md §14) assert
/// this is true as a release build contract rather than skipping. Backup
/// fixtures use it only to decide whether to additionally seed an FTS index in
/// the synthetic store; they never skip.
bool sqliteHasFts5() {
  final Database db = sqlite3.openInMemory();
  try {
    db.execute('CREATE VIRTUAL TABLE _probe USING fts5(x)');
    return true;
  } on Object {
    return false;
  } finally {
    db.close();
  }
}
