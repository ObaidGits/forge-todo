import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/import_plan.dart';
import 'package:forge/features/backup/domain/portable_tables.dart';
import 'package:forge/features/backup/infrastructure/human_readable_codecs.dart';

/// Adapts [IdGenerator] to the pure planner's [ImportIdMinter].
final class _IdGeneratorMinter implements ImportIdMinter {
  const _IdGeneratorMinter(this._generator);

  final IdGenerator _generator;

  @override
  String mint() => _generator.uuidV7();
}

/// A previewable import: the decoded document plus the computed collision-remap
/// plan (`R-BACKUP-005`). Present this to the user before committing.
final class HumanReadableImportPreview {
  const HumanReadableImportPreview({
    required this.document,
    required this.plan,
  });

  final ExportDocument document;
  final ImportPlan plan;
}

/// Result of committing an import.
final class HumanReadableImportResult {
  const HumanReadableImportResult({
    required this.insertedCount,
    required this.remappedCount,
    required this.skippedCount,
    required this.tombstoneBlockedCount,
  });

  final int insertedCount;
  final int remappedCount;
  final int skippedCount;
  final int tombstoneBlockedCount;
}

/// Raised when an import cannot be committed. The live generation is never left
/// partially modified: commit runs in one transaction that rolls back on any
/// failure.
final class HumanReadableImportException implements Exception {
  const HumanReadableImportException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() =>
      'HumanReadableImportException($code${detail == null ? '' : ': $detail'})';
}

/// Imports a human-readable document into the live generation with a
/// collision-remap preview (`R-BACKUP-005`, `R-GEN-003`).
///
/// The flow is deliberately two-phase so the UI can show the preview before any
/// write:
///
/// 1. [preview] decodes the document, reads the colliding existing rows, and
///    computes an [ImportPlan]. IDs that collide with a *different* existing
///    row are remapped to fresh IDs; IDs that collide with a tombstone are
///    remapped so the deletion can never resurrect; incoming tombstones are
///    skipped. Import never silently overwrites.
/// 2. [commit] applies the plan in one transaction, rewriting every remapped
///    reference so links stay intact.
final class HumanReadableImporter {
  HumanReadableImporter({
    required this.opener,
    required this.idGenerator,
    this.tables = defaultPortableTables,
    this.logger,
  });

  final MigrationConnectionOpener opener;
  final IdGenerator idGenerator;
  final List<PortableTable> tables;
  final StructuredLogger? logger;

  static const String _component = 'backup.import.human';

  /// Decodes [bytes] and computes the collision-remap preview against the live
  /// generation without mutating it.
  Future<HumanReadableImportPreview> preview({
    required String generationDirectory,
    required List<int> bytes,
    required HumanReadableFormat format,
  }) async {
    final ExportDocument document = humanReadableCodec(format).decode(bytes);
    final MigrationConnection conn = await opener.open(
      generationDirectory,
      createIfMissing: false,
    );
    try {
      final Map<String, Map<String, ExistingRow>> existing =
          await _readExisting(conn, document);
      final ImportPlan plan = ImportPlanner(tables: tables).plan(
        document: document,
        existing: existing,
        minter: _IdGeneratorMinter(idGenerator),
      );
      return HumanReadableImportPreview(document: document, plan: plan);
    } finally {
      await conn.dispose();
    }
  }

  /// Commits a previously computed [preview] transactionally.
  Future<HumanReadableImportResult> commit({
    required String generationDirectory,
    required HumanReadableImportPreview preview,
  }) async {
    final MigrationConnection conn = await opener.open(
      generationDirectory,
      createIfMissing: false,
    );
    try {
      int inserted = 0;
      await conn.transaction(() async {
        for (final ImportRowPlan rowPlan in preview.plan.rows) {
          if (!rowPlan.writes) {
            continue;
          }
          await _insertRow(conn, preview, rowPlan);
          inserted += 1;
        }
      });
      logger?.log(
        level: LogLevel.info,
        component: _component,
        eventCode: 'imported',
      );
      final ImportPlan plan = preview.plan;
      return HumanReadableImportResult(
        insertedCount: inserted,
        remappedCount: plan.collisionRemapCount,
        skippedCount: plan.exactMatchCount + plan.incomingTombstoneSkippedCount,
        tombstoneBlockedCount: plan.tombstoneBlockedCount,
      );
    } finally {
      await conn.dispose();
    }
  }

  Future<Map<String, Map<String, ExistingRow>>> _readExisting(
    MigrationConnection conn,
    ExportDocument document,
  ) async {
    final Map<String, PortableTable> byName = <String, PortableTable>{
      for (final PortableTable t in tables) t.name: t,
    };
    final Set<String> present = (await conn.userTables()).toSet();
    final Map<String, Map<String, ExistingRow>> result =
        <String, Map<String, ExistingRow>>{};
    for (final ExportTable table in document.tables) {
      final PortableTable? config = byName[table.name];
      if (config == null || !present.contains(table.name)) {
        continue;
      }
      final List<Map<String, Object?>> rows = await conn.select(
        'SELECT * FROM "${table.name}"',
      );
      final Map<String, ExistingRow> map = <String, ExistingRow>{};
      for (final Map<String, Object?> row in rows) {
        final Object? id = row[config.primaryKeyColumn];
        if (id is! String) {
          continue;
        }
        final bool tombstone = _isTombstone(row, config);
        map[id] = ExistingRow(
          values: <String, String?>{
            for (final MapEntry<String, Object?> e in row.entries)
              e.key: _cell(e.value),
          },
          isTombstone: tombstone,
        );
      }
      result[table.name] = map;
    }
    return result;
  }

  Future<void> _insertRow(
    MigrationConnection conn,
    HumanReadableImportPreview preview,
    ImportRowPlan rowPlan,
  ) async {
    final ExportTable? table = preview.document.table(rowPlan.table);
    if (table == null) {
      throw HumanReadableImportException('missing_table', rowPlan.table);
    }
    final PortableTable config = tables.firstWhere(
      (PortableTable t) => t.name == rowPlan.table,
      orElse: () =>
          throw HumanReadableImportException('unknown_table', rowPlan.table),
    );
    final Map<String, String?> source = table.rows.firstWhere(
      (Map<String, String?> r) =>
          r[config.primaryKeyColumn] == rowPlan.originalId,
      orElse: () =>
          throw HumanReadableImportException('missing_row', rowPlan.originalId),
    );
    final Map<String, String> remaps = preview.plan.remaps;
    final List<String> columns = table.columns;
    final List<Object?> values = <Object?>[];
    for (final String column in columns) {
      if (column == config.primaryKeyColumn) {
        values.add(rowPlan.finalId);
        continue;
      }
      final String? cell = source[column];
      // Rewrite any reference that points at a remapped ID (`R-GEN-003`).
      values.add(
        cell != null && remaps.containsKey(cell) ? remaps[cell] : cell,
      );
    }
    final String columnList = columns.map((String c) => '"$c"').join(', ');
    final String placeholders = List<String>.filled(
      columns.length,
      '?',
    ).join(', ');
    try {
      await conn.execute(
        'INSERT INTO "${rowPlan.table}" ($columnList) VALUES ($placeholders)',
        values,
      );
    } on Object catch (error) {
      throw HumanReadableImportException('insert_failed', error.toString());
    }
  }

  bool _isTombstone(Map<String, Object?> row, PortableTable config) {
    final String? column = config.tombstoneColumn;
    if (column == null) {
      return false;
    }
    return row[column] != null;
  }

  String? _cell(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    if (value is int || value is double || value is BigInt || value is bool) {
      return value.toString();
    }
    return value.toString();
  }
}
