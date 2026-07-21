import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';

/// Bookkeeping table name used to persist backfill progress inside the shadow
/// store so an interrupted migration resumes instead of restarting.
const String kBackfillProgressTable = '_forge_migration_backfill_progress';

/// Outcome of a completed (or resumed-to-completion) backfill pass.
final class BackfillReport {
  const BackfillReport({
    required this.rowsCopied,
    required this.tablesCompleted,
  });

  /// Rows copied during *this* invocation (excludes rows a prior interrupted
  /// run already committed).
  final int rowsCopied;
  final int tablesCompleted;
}

/// Copies rows from the source generation into the shadow generation in bounded
/// batches, persisting a per-table cursor after every committed batch.
///
/// Because each batch inserts rows *and* advances the cursor in one shadow
/// transaction, a crash between batches leaves the cursor pointing exactly at
/// the last durably copied row. Re-running resumes after that cursor and never
/// duplicates or skips a row (data-model §5.3, NFR-REL-002).
final class ResumableBackfill {
  const ResumableBackfill({this.batchSize = 500})
    : assert(batchSize > 0, 'Batch size must be positive.');

  final int batchSize;

  Future<void> ensureProgressTable(MigrationConnection shadow) async {
    await shadow.execute(
      'CREATE TABLE IF NOT EXISTS "$kBackfillProgressTable" ('
      'table_name TEXT PRIMARY KEY, '
      'last_key TEXT, '
      'rows_copied INTEGER NOT NULL DEFAULT 0, '
      'done INTEGER NOT NULL DEFAULT 0)',
    );
  }

  Future<BackfillReport> run({
    required MigrationConnection source,
    required MigrationConnection shadow,
    required List<BackfillTable> tables,
  }) async {
    await ensureProgressTable(shadow);
    int rowsCopied = 0;
    int tablesCompleted = 0;
    for (final BackfillTable table in tables) {
      final _TableProgress progress = await _loadProgress(shadow, table.name);
      if (progress.done) {
        tablesCompleted += 1;
        continue;
      }
      rowsCopied += await _backfillTable(
        source: source,
        shadow: shadow,
        table: table,
        startAfterKey: progress.lastKey,
      );
      tablesCompleted += 1;
    }
    return BackfillReport(
      rowsCopied: rowsCopied,
      tablesCompleted: tablesCompleted,
    );
  }

  Future<int> _backfillTable({
    required MigrationConnection source,
    required MigrationConnection shadow,
    required BackfillTable table,
    required String? startAfterKey,
  }) async {
    String? cursor = startAfterKey;
    int copied = 0;
    while (true) {
      final List<Map<String, Object?>> batch = await _readBatch(
        source,
        table,
        cursor,
      );
      if (batch.isEmpty) {
        await _markDone(shadow, table.name);
        break;
      }
      final String batchCursor = batch.last[table.orderByColumn]!.toString();
      final int batchCount = batch.length;
      // Inserts and cursor advance commit together: the atomic resume boundary.
      await shadow.transaction(() async {
        for (final Map<String, Object?> sourceRow in batch) {
          final Map<String, Object?> row = table.transform(sourceRow);
          await _insertRow(shadow, table.name, row);
        }
        await _advanceCursor(shadow, table.name, batchCursor, batchCount);
      });
      copied += batchCount;
      cursor = batchCursor;
      if (batchCount < batchSize) {
        await _markDone(shadow, table.name);
        break;
      }
    }
    return copied;
  }

  Future<List<Map<String, Object?>>> _readBatch(
    MigrationConnection source,
    BackfillTable table,
    String? afterKey,
  ) {
    final String column = table.orderByColumn;
    if (afterKey == null) {
      return source.select(
        'SELECT * FROM "${table.name}" ORDER BY "$column" LIMIT ?',
        <Object?>[batchSize],
      );
    }
    return source.select(
      'SELECT * FROM "${table.name}" WHERE "$column" > ? '
      'ORDER BY "$column" LIMIT ?',
      <Object?>[afterKey, batchSize],
    );
  }

  Future<void> _insertRow(
    MigrationConnection shadow,
    String table,
    Map<String, Object?> row,
  ) async {
    final List<String> columns = row.keys.toList(growable: false);
    final String columnList = columns.map((String c) => '"$c"').join(', ');
    final String placeholders = List<String>.filled(
      columns.length,
      '?',
    ).join(', ');
    final List<Object?> values = columns
        .map((String c) => row[c])
        .toList(growable: false);
    await shadow.execute(
      'INSERT INTO "$table" ($columnList) VALUES ($placeholders)',
      values,
    );
  }

  Future<_TableProgress> _loadProgress(
    MigrationConnection shadow,
    String table,
  ) async {
    final List<Map<String, Object?>> rows = await shadow.select(
      'SELECT last_key, done FROM "$kBackfillProgressTable" '
      'WHERE table_name = ?',
      <Object?>[table],
    );
    if (rows.isEmpty) {
      return const _TableProgress(lastKey: null, done: false);
    }
    final Map<String, Object?> row = rows.first;
    return _TableProgress(
      lastKey: row['last_key'] as String?,
      done: (row['done'] as int? ?? 0) != 0,
    );
  }

  Future<void> _advanceCursor(
    MigrationConnection shadow,
    String table,
    String lastKey,
    int batchCount,
  ) async {
    await shadow.execute(
      'INSERT INTO "$kBackfillProgressTable" '
      '(table_name, last_key, rows_copied, done) VALUES (?, ?, ?, 0) '
      'ON CONFLICT(table_name) DO UPDATE SET '
      'last_key = excluded.last_key, '
      'rows_copied = rows_copied + ?',
      <Object?>[table, lastKey, batchCount, batchCount],
    );
  }

  Future<void> _markDone(MigrationConnection shadow, String table) async {
    await shadow.execute(
      'INSERT INTO "$kBackfillProgressTable" '
      '(table_name, last_key, rows_copied, done) VALUES (?, NULL, 0, 1) '
      'ON CONFLICT(table_name) DO UPDATE SET done = 1',
      <Object?>[table],
    );
  }
}

final class _TableProgress {
  const _TableProgress({required this.lastKey, required this.done});

  final String? lastKey;
  final bool done;
}
