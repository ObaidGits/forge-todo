import 'dart:io' as io;
import 'dart:typed_data';

import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Production [MigrationConnectionOpener] over the sqlite3mc-encrypted
/// generation store.
///
/// This is the encrypted sibling of the test-only `Sqlite3MigrationConnectionOpener`:
/// it opens the same on-disk store the runtime uses (via the sqlite3mc native
/// asset) but applies the profile cipher key with `PRAGMA key` before any other
/// access, exactly mirroring [Sqlite3mcEncryptedStoreOpener]. Every page read
/// or written therefore goes through the sqlite3mc cipher (ADR-0001).
///
/// It backs both directions of the recovery feature:
///
/// - **Export** opens an existing encrypted generation for read-only snapshot
///   (`VACUUM INTO`, which produces a copy encrypted with the same key).
/// - **Staged restore** opens the freshly materialised staging generation (also
///   keyed with the same cipher key) to verify it before the atomic switch, and
///   re-opens it after activation.
///
/// The key bytes are copied defensively at construction and held for the
/// opener's lifetime (mirroring the note-draft cipher): the composition root
/// releases a single [KeyVault] lease, hands the bytes here, then disposes the
/// lease. A wrong/absent key never resets data — sqlite3mc simply fails to
/// decrypt the header and the caller (staged restore / export) surfaces a
/// non-destructive failure (R-SEC-001).
final class EncryptedMigrationConnectionOpener
    implements MigrationConnectionOpener {
  EncryptedMigrationConnectionOpener({
    required Uint8List keyBytes,
    this.storeFileName = 'forge.sqlite',
  }) : _keyHex = _toHex(keyBytes);

  /// The store file name inside each generation directory. Matches the runtime
  /// encrypted store's database file name so an activated restored generation
  /// is opened by the runtime on next boot.
  final String storeFileName;

  /// Hex-encoded cipher key retained for the single `PRAGMA key` applied to
  /// every opened connection. Hex (not the raw bytes) is kept because that is
  /// the exact form the pragma consumes.
  final String _keyHex;

  @override
  Future<MigrationConnection> open(
    String generationDirectory, {
    required bool createIfMissing,
  }) async {
    final io.Directory dir = io.Directory(generationDirectory);
    if (createIfMissing) {
      await dir.create(recursive: true);
    } else if (!await dir.exists()) {
      throw MigrationConnectionException(
        'Generation directory missing at ${dir.path}.',
      );
    }
    final String path = '${dir.path}${io.Platform.pathSeparator}$storeFileName';
    if (!createIfMissing && !io.File(path).existsSync()) {
      throw MigrationConnectionException('Store missing at $path.');
    }

    final sqlite.Database db = sqlite.sqlite3.open(path);
    try {
      // Apply the cipher key BEFORE any other access so every page read/written
      // goes through the sqlite3mc cipher. Same key form as the runtime store.
      db.execute('PRAGMA key = "x\'$_keyHex\'"');
      db.execute('PRAGMA foreign_keys = ON');
      return EncryptedMigrationConnection(db);
    } on Object {
      db.close();
      rethrow;
    }
  }

  static const String _hexAlphabet = '0123456789abcdef';

  static String _toHex(Uint8List bytes) {
    final StringBuffer out = StringBuffer();
    for (final int byte in bytes) {
      out
        ..write(_hexAlphabet[(byte >> 4) & 0x0f])
        ..write(_hexAlphabet[byte & 0x0f]);
    }
    return out.toString();
  }
}

/// A [MigrationConnection] over a keyed sqlite3mc [sqlite.Database].
///
/// Behaviourally identical to the migration harness connection (execute /
/// select / transaction), differing only in that its backing connection is
/// opened through the encrypted store cipher.
final class EncryptedMigrationConnection implements MigrationConnection {
  EncryptedMigrationConnection(this._db);

  final sqlite.Database _db;
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
    final sqlite.PreparedStatement statement = _db.prepare(sql);
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
    final sqlite.ResultSet result = arguments.isEmpty
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
