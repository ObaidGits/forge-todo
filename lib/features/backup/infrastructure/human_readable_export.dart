import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/portable_tables.dart';
import 'package:forge/features/backup/infrastructure/human_readable_codecs.dart';

/// Result of a human-readable export: the rendered bytes and a small summary.
final class HumanReadableExportResult {
  const HumanReadableExportResult({
    required this.bytes,
    required this.format,
    required this.document,
  });

  final List<int> bytes;
  final HumanReadableFormat format;
  final ExportDocument document;

  int get tableCount => document.tables.length;
  int get rowCount =>
      document.tables.fold(0, (int sum, ExportTable t) => sum + t.rows.length);
}

/// Exports portable domain data to a human-readable JSON, Markdown, or CSV
/// document (`R-BACKUP-005`).
///
/// This reads the live generation only; it never writes. It is deliberately
/// separate from the authenticated FBC1 backup: the produced document is
/// clearly labeled as less secure. Only the portable table set participates;
/// operational, security, sync, search, and generation state never leaves the
/// device in this projection. Tombstoned rows are excluded by default so the
/// export is a clean projection of live data.
final class HumanReadableExporter {
  HumanReadableExporter({
    required this.opener,
    required this.now,
    this.tables = defaultPortableTables,
    this.includeTombstones = false,
    this.logger,
  });

  final MigrationConnectionOpener opener;
  final DateTime Function() now;
  final List<PortableTable> tables;
  final bool includeTombstones;
  final StructuredLogger? logger;

  static const String _component = 'backup.export.human';

  Future<HumanReadableExportResult> export({
    required String generationDirectory,
    required HumanReadableFormat format,
  }) async {
    final MigrationConnection conn = await opener.open(
      generationDirectory,
      createIfMissing: false,
    );
    try {
      final Set<String> present = (await conn.userTables()).toSet();
      final List<ExportTable> exportTables = <ExportTable>[];
      for (final PortableTable table in tables) {
        if (!present.contains(table.name)) {
          continue;
        }
        exportTables.add(await _readTable(conn, table));
      }
      final ExportDocument document = ExportDocument(
        createdAtUtcMicros: now().toUtc().microsecondsSinceEpoch,
        profileId: await _readProfileId(conn, present),
        tables: exportTables,
      );
      final List<int> bytes = humanReadableCodec(format).encode(document);
      logger?.log(
        level: LogLevel.info,
        component: _component,
        eventCode: 'exported',
      );
      return HumanReadableExportResult(
        bytes: bytes,
        format: format,
        document: document,
      );
    } finally {
      await conn.dispose();
    }
  }

  Future<ExportTable> _readTable(
    MigrationConnection conn,
    PortableTable table,
  ) async {
    final List<String> columns = await _columns(conn, table.name);
    final String? tombstone = table.tombstoneColumn;
    final String where =
        (!includeTombstones && tombstone != null && columns.contains(tombstone))
        ? ' WHERE "$tombstone" IS NULL'
        : '';
    final List<Map<String, Object?>> rows = await conn.select(
      'SELECT * FROM "${table.name}"$where '
      'ORDER BY "${table.primaryKeyColumn}"',
    );
    return ExportTable(
      name: table.name,
      columns: columns,
      rows: <Map<String, String?>>[
        for (final Map<String, Object?> row in rows)
          <String, String?>{
            for (final String column in columns) column: _cell(row[column]),
          },
      ],
    );
  }

  Future<List<String>> _columns(MigrationConnection conn, String table) async {
    final List<Map<String, Object?>> info = await conn.select(
      'PRAGMA table_info("$table")',
    );
    return <String>[
      for (final Map<String, Object?> column in info) column['name']! as String,
    ];
  }

  Future<String?> _readProfileId(
    MigrationConnection conn,
    Set<String> present,
  ) async {
    if (!present.contains('profiles')) {
      return null;
    }
    final List<Map<String, Object?>> rows = await conn.select(
      'SELECT id FROM profiles ORDER BY id LIMIT 1',
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['id'] as String?;
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
    // Blobs and other exotic types are not part of the portable text surface.
    throw HumanReadableFormatException(
      'unsupported_cell',
      value.runtimeType.toString(),
    );
  }
}
