/// Pure domain model for the V1 human-readable, portable export/import
/// (`R-BACKUP-005`).
///
/// This is deliberately **not** the authenticated FBC1 backup format. It is a
/// separately labeled, human-readable projection of portable domain data in
/// JSON, Markdown, or CSV. It is less secure than an FBC1 archive unless the
/// user encrypts it externally, and every rendered document carries that
/// notice.
///
/// The model is cipher-, database-, and Flutter-neutral so it can be unit- and
/// property-tested in isolation. Cells are nullable strings: the exporter
/// renders every database value to its canonical string form (or null),
/// keeping JSON, Markdown, and CSV a single shared shape.
library;

/// The three human-readable formats a document can be rendered to or parsed
/// from (`R-BACKUP-005`).
enum HumanReadableFormat {
  json('json', 'application/json', '.json'),
  markdown('markdown', 'text/markdown', '.md'),
  csv('csv', 'text/csv', '.csv');

  const HumanReadableFormat(this.id, this.mimeType, this.fileExtension);

  final String id;
  final String mimeType;
  final String fileExtension;
}

/// The current human-readable document schema version. Bumped only additively
/// so older exports remain parseable.
const int humanReadableFormatVersion = 1;

/// A single portable table inside an [ExportDocument]: an ordered column list
/// and the rows projected as canonical string cells.
final class ExportTable {
  ExportTable({
    required this.name,
    required List<String> columns,
    required List<Map<String, String?>> rows,
  }) : columns = List<String>.unmodifiable(columns),
       rows = List<Map<String, String?>>.unmodifiable(
         rows.map(Map<String, String?>.unmodifiable),
       ) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Table name must not be empty.');
    }
    if (columns.toSet().length != columns.length) {
      throw ArgumentError.value(columns, 'columns', 'Columns must be unique.');
    }
  }

  final String name;
  final List<String> columns;
  final List<Map<String, String?>> rows;

  @override
  bool operator ==(Object other) =>
      other is ExportTable &&
      other.name == name &&
      _listEquals(other.columns, columns) &&
      _rowsEqual(other.rows, rows);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(columns), rows.length);
}

/// A complete human-readable export: metadata plus an ordered list of portable
/// tables. Equality is structural so round-trip tests can assert fidelity.
final class ExportDocument {
  ExportDocument({
    required this.createdAtUtcMicros,
    required this.profileId,
    required List<ExportTable> tables,
    this.formatVersion = humanReadableFormatVersion,
  }) : tables = List<ExportTable>.unmodifiable(tables);

  final int formatVersion;
  final int createdAtUtcMicros;

  /// The profile the export was taken from, or null when unknown. Never a
  /// secret; it is an opaque local identifier.
  final String? profileId;

  final List<ExportTable> tables;

  ExportTable? table(String name) {
    for (final ExportTable table in tables) {
      if (table.name == name) {
        return table;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ExportDocument &&
      other.formatVersion == formatVersion &&
      other.createdAtUtcMicros == createdAtUtcMicros &&
      other.profileId == profileId &&
      _listEquals(other.tables, tables);

  @override
  int get hashCode => Object.hash(
    formatVersion,
    createdAtUtcMicros,
    profileId,
    Object.hashAll(tables),
  );
}

/// Raised when a human-readable document cannot be parsed. Fail-closed: a
/// malformed document never partially imports.
final class HumanReadableFormatException implements Exception {
  const HumanReadableFormatException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() =>
      'HumanReadableFormatException($code${detail == null ? '' : ': $detail'})';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _rowsEqual(List<Map<String, String?>> a, List<Map<String, String?>> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i += 1) {
    final Map<String, String?> rowA = a[i];
    final Map<String, String?> rowB = b[i];
    if (rowA.length != rowB.length) {
      return false;
    }
    for (final MapEntry<String, String?> entry in rowA.entries) {
      if (!rowB.containsKey(entry.key) || rowB[entry.key] != entry.value) {
        return false;
      }
    }
  }
  return true;
}
