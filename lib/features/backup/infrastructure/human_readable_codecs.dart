import 'dart:convert';

import 'package:forge/features/backup/domain/human_readable_export.dart';

/// The mandatory notice stamped onto every human-readable export. It states
/// plainly that this is not the authenticated backup and is less secure unless
/// the user encrypts it externally (`R-BACKUP-005`, ux-design §"content style").
const String humanReadableNotice =
    'Human-readable export. This is NOT the encrypted Forge backup and is less '
    'secure: anyone with this file can read it unless you encrypt it yourself. '
    'Keep it private.';

/// Encodes/decodes an [ExportDocument] to and from a single human-readable
/// format. Concrete codecs live below; select one via [humanReadableCodec].
abstract interface class HumanReadableCodec {
  HumanReadableFormat get format;

  /// Renders [document] to UTF-8 bytes in this codec's format.
  List<int> encode(ExportDocument document);

  /// Parses UTF-8 [bytes] back into an [ExportDocument]. Throws
  /// [HumanReadableFormatException] on malformed input; never partial output.
  ExportDocument decode(List<int> bytes);
}

/// Returns the codec for [format].
HumanReadableCodec humanReadableCodec(HumanReadableFormat format) =>
    switch (format) {
      HumanReadableFormat.json => const JsonHumanReadableCodec(),
      HumanReadableFormat.markdown => const MarkdownHumanReadableCodec(),
      HumanReadableFormat.csv => const CsvHumanReadableCodec(),
    };

// ---------------------------------------------------------------------------
// JSON — the canonical, lossless format used by the import pipeline.
// ---------------------------------------------------------------------------

final class JsonHumanReadableCodec implements HumanReadableCodec {
  const JsonHumanReadableCodec();

  @override
  HumanReadableFormat get format => HumanReadableFormat.json;

  @override
  List<int> encode(ExportDocument document) {
    final Map<String, Object?> root = <String, Object?>{
      'forge_human_readable': <String, Object?>{
        'notice': humanReadableNotice,
        'format': HumanReadableFormat.json.id,
        'format_version': document.formatVersion,
        'created_at_utc_micros': document.createdAtUtcMicros,
        'profile_id': document.profileId,
        'tables': <Object?>[
          for (final ExportTable table in document.tables)
            <String, Object?>{
              'name': table.name,
              'columns': table.columns,
              'rows': <Object?>[
                for (final Map<String, String?> row in table.rows)
                  <String, Object?>{
                    for (final String column in table.columns)
                      column: row[column],
                  },
              ],
            },
        ],
      },
    };
    return utf8.encode(const JsonEncoder.withIndent('  ').convert(root));
  }

  @override
  ExportDocument decode(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw HumanReadableFormatException('json_malformed', error.message);
    }
    if (decoded is! Map<String, Object?>) {
      throw const HumanReadableFormatException('json_root');
    }
    final Object? envelope = decoded['forge_human_readable'];
    if (envelope is! Map<String, Object?>) {
      throw const HumanReadableFormatException('json_envelope');
    }
    if (envelope['format'] != HumanReadableFormat.json.id) {
      throw const HumanReadableFormatException('json_format');
    }
    final Object? version = envelope['format_version'];
    if (version is! int || version > humanReadableFormatVersion) {
      throw HumanReadableFormatException('json_version', '$version');
    }
    final Object? tablesJson = envelope['tables'];
    if (tablesJson is! List<Object?>) {
      throw const HumanReadableFormatException('json_tables');
    }
    final List<ExportTable> tables = <ExportTable>[];
    for (final Object? tableJson in tablesJson) {
      if (tableJson is! Map<String, Object?>) {
        throw const HumanReadableFormatException('json_table');
      }
      final Object? name = tableJson['name'];
      final Object? columnsJson = tableJson['columns'];
      final Object? rowsJson = tableJson['rows'];
      if (name is! String ||
          columnsJson is! List<Object?> ||
          rowsJson is! List<Object?>) {
        throw const HumanReadableFormatException('json_table_shape');
      }
      final List<String> columns = <String>[
        for (final Object? c in columnsJson)
          if (c is String)
            c
          else
            throw const HumanReadableFormatException('json_column'),
      ];
      final List<Map<String, String?>> rows = <Map<String, String?>>[];
      for (final Object? rowJson in rowsJson) {
        if (rowJson is! Map<String, Object?>) {
          throw const HumanReadableFormatException('json_row');
        }
        rows.add(<String, String?>{
          for (final String column in columns) column: _cell(rowJson[column]),
        });
      }
      tables.add(ExportTable(name: name, columns: columns, rows: rows));
    }
    return ExportDocument(
      formatVersion: version,
      createdAtUtcMicros: _int(envelope['created_at_utc_micros']),
      profileId: envelope['profile_id'] as String?,
      tables: tables,
    );
  }

  String? _cell(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    if (value is int || value is bool || value is double) {
      return value.toString();
    }
    throw HumanReadableFormatException(
      'json_cell',
      value.runtimeType.toString(),
    );
  }

  int _int(Object? value) {
    if (value is int) {
      return value;
    }
    throw const HumanReadableFormatException('json_created_at');
  }
}

// ---------------------------------------------------------------------------
// CSV — one artifact holding metadata comments plus per-table blocks. An
// unquoted empty field is null; a quoted empty field ("") is an empty string,
// so the format round-trips losslessly.
// ---------------------------------------------------------------------------

final class CsvHumanReadableCodec implements HumanReadableCodec {
  const CsvHumanReadableCodec();

  @override
  HumanReadableFormat get format => HumanReadableFormat.csv;

  @override
  List<int> encode(ExportDocument document) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('# $humanReadableNotice')
      ..writeln('# forge_human_readable')
      ..writeln('# format=${HumanReadableFormat.csv.id}')
      ..writeln('# format_version=${document.formatVersion}')
      ..writeln('# created_at_utc_micros=${document.createdAtUtcMicros}')
      ..writeln('# profile_id=${document.profileId ?? ''}');
    for (final ExportTable table in document.tables) {
      buffer
        ..writeln()
        ..writeln('# table=${table.name}')
        ..writeln(_row(table.columns.map<String?>((String c) => c).toList()));
      for (final Map<String, String?> row in table.rows) {
        buffer.writeln(
          _row(<String?>[
            for (final String column in table.columns) row[column],
          ]),
        );
      }
    }
    return utf8.encode(buffer.toString());
  }

  String _row(List<String?> cells) => cells.map(_encodeCell).join(',');

  String _encodeCell(String? cell) {
    if (cell == null) {
      return '';
    }
    final bool mustQuote =
        cell.isEmpty ||
        cell.contains(',') ||
        cell.contains('"') ||
        cell.contains('\n') ||
        cell.contains('\r');
    if (!mustQuote) {
      return cell;
    }
    return '"${cell.replaceAll('"', '""')}"';
  }

  @override
  ExportDocument decode(List<int> bytes) {
    final List<String> lines = const LineSplitter().convert(utf8.decode(bytes));
    int formatVersion = humanReadableFormatVersion;
    int createdAt = 0;
    String? profileId;
    final List<ExportTable> tables = <ExportTable>[];

    String? currentName;
    List<String>? currentColumns;
    List<Map<String, String?>> currentRows = <Map<String, String?>>[];

    void flush() {
      if (currentName != null && currentColumns != null) {
        tables.add(
          ExportTable(
            name: currentName!,
            columns: currentColumns!,
            rows: currentRows,
          ),
        );
      }
      currentName = null;
      currentColumns = null;
      currentRows = <Map<String, String?>>[];
    }

    for (final String line in lines) {
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('#')) {
        final String meta = line.substring(1).trim();
        if (meta.startsWith('table=')) {
          flush();
          currentName = meta.substring('table='.length);
        } else if (meta.startsWith('format_version=')) {
          formatVersion =
              int.tryParse(meta.substring('format_version='.length)) ??
              humanReadableFormatVersion;
        } else if (meta.startsWith('created_at_utc_micros=')) {
          createdAt =
              int.tryParse(meta.substring('created_at_utc_micros='.length)) ??
              0;
        } else if (meta.startsWith('profile_id=')) {
          final String value = meta.substring('profile_id='.length);
          profileId = value.isEmpty ? null : value;
        }
        continue;
      }
      if (currentName == null) {
        throw const HumanReadableFormatException('csv_row_before_table');
      }
      final List<String?> fields = _parseLine(line);
      if (currentColumns == null) {
        currentColumns = <String>[for (final String? f in fields) f ?? ''];
        continue;
      }
      if (fields.length != currentColumns!.length) {
        throw HumanReadableFormatException(
          'csv_field_count',
          '${fields.length} != ${currentColumns!.length}',
        );
      }
      currentRows.add(<String, String?>{
        for (int i = 0; i < currentColumns!.length; i += 1)
          currentColumns![i]: fields[i],
      });
    }
    flush();
    if (formatVersion > humanReadableFormatVersion) {
      throw HumanReadableFormatException('csv_version', '$formatVersion');
    }
    return ExportDocument(
      formatVersion: formatVersion,
      createdAtUtcMicros: createdAt,
      profileId: profileId,
      tables: tables,
    );
  }

  /// Parses one RFC 4180 line. Unquoted empty → null; quoted empty → ''.
  List<String?> _parseLine(String line) {
    final List<String?> out = <String?>[];
    final StringBuffer field = StringBuffer();
    bool quoted = false;
    bool wasQuoted = false;
    int i = 0;
    while (i < line.length) {
      final String ch = line[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          quoted = false;
          i += 1;
          continue;
        }
        field.write(ch);
        i += 1;
        continue;
      }
      if (ch == '"') {
        quoted = true;
        wasQuoted = true;
        i += 1;
        continue;
      }
      if (ch == ',') {
        out.add(_finishField(field, wasQuoted));
        field.clear();
        wasQuoted = false;
        i += 1;
        continue;
      }
      field.write(ch);
      i += 1;
    }
    out.add(_finishField(field, wasQuoted));
    return out;
  }

  String? _finishField(StringBuffer field, bool wasQuoted) {
    final String text = field.toString();
    if (!wasQuoted && text.isEmpty) {
      return null;
    }
    return text;
  }
}

// ---------------------------------------------------------------------------
// Markdown — a human-readable document with a heading per table and a GitHub
// table of rows. Null cells and empty strings both render as an empty cell, so
// Markdown round-trips typical non-empty content (ids, titles, statuses);
// JSON/CSV remain the lossless formats.
// ---------------------------------------------------------------------------

final class MarkdownHumanReadableCodec implements HumanReadableCodec {
  const MarkdownHumanReadableCodec();

  @override
  HumanReadableFormat get format => HumanReadableFormat.markdown;

  @override
  List<int> encode(ExportDocument document) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('# Forge human-readable export')
      ..writeln()
      ..writeln('> $humanReadableNotice')
      ..writeln()
      ..writeln('- format: ${HumanReadableFormat.markdown.id}')
      ..writeln('- format_version: ${document.formatVersion}')
      ..writeln('- created_at_utc_micros: ${document.createdAtUtcMicros}')
      ..writeln('- profile_id: ${document.profileId ?? ''}');
    for (final ExportTable table in document.tables) {
      buffer
        ..writeln()
        ..writeln('## ${table.name}')
        ..writeln()
        ..writeln('| ${table.columns.map(_escape).join(' | ')} |')
        ..writeln('| ${table.columns.map((_) => '---').join(' | ')} |');
      for (final Map<String, String?> row in table.rows) {
        buffer.writeln(
          '| ${table.columns.map((String c) => _escape(row[c] ?? '')).join(' | ')} |',
        );
      }
    }
    return utf8.encode(buffer.toString());
  }

  String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('|', r'\|')
      .replaceAll('\n', ' ');

  String _unescape(String value) {
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < value.length) {
      if (value[i] == r'\' && i + 1 < value.length) {
        out.write(value[i + 1]);
        i += 2;
        continue;
      }
      out.write(value[i]);
      i += 1;
    }
    return out.toString();
  }

  @override
  ExportDocument decode(List<int> bytes) {
    final List<String> lines = const LineSplitter().convert(utf8.decode(bytes));
    int formatVersion = humanReadableFormatVersion;
    int createdAt = 0;
    String? profileId;
    final List<ExportTable> tables = <ExportTable>[];

    String? currentName;
    List<String>? currentColumns;
    List<Map<String, String?>> currentRows = <Map<String, String?>>[];
    int tableLineIndex = 0;

    void flush() {
      if (currentName != null && currentColumns != null) {
        tables.add(
          ExportTable(
            name: currentName!,
            columns: currentColumns!,
            rows: currentRows,
          ),
        );
      }
      currentName = null;
      currentColumns = null;
      currentRows = <Map<String, String?>>[];
      tableLineIndex = 0;
    }

    for (final String raw in lines) {
      final String line = raw.trimRight();
      if (line.startsWith('## ')) {
        flush();
        currentName = line.substring(3).trim();
        continue;
      }
      if (currentName == null) {
        if (line.startsWith('- format_version:')) {
          formatVersion =
              int.tryParse(line.split(':').last.trim()) ??
              humanReadableFormatVersion;
        } else if (line.startsWith('- created_at_utc_micros:')) {
          createdAt = int.tryParse(line.split(':').last.trim()) ?? 0;
        } else if (line.startsWith('- profile_id:')) {
          final String value = line.substring('- profile_id:'.length).trim();
          profileId = value.isEmpty ? null : value;
        }
        continue;
      }
      if (!line.startsWith('|')) {
        continue;
      }
      final List<String> cells = _parseTableRow(line);
      if (tableLineIndex == 0) {
        currentColumns = cells;
        tableLineIndex += 1;
        continue;
      }
      if (tableLineIndex == 1) {
        // Separator row (| --- | --- |). Skip.
        tableLineIndex += 1;
        continue;
      }
      if (cells.length != currentColumns!.length) {
        throw HumanReadableFormatException(
          'markdown_field_count',
          '${cells.length} != ${currentColumns!.length}',
        );
      }
      currentRows.add(<String, String?>{
        for (int i = 0; i < currentColumns!.length; i += 1)
          currentColumns![i]: cells[i].isEmpty ? null : cells[i],
      });
    }
    flush();
    if (formatVersion > humanReadableFormatVersion) {
      throw HumanReadableFormatException('markdown_version', '$formatVersion');
    }
    return ExportDocument(
      formatVersion: formatVersion,
      createdAtUtcMicros: createdAt,
      profileId: profileId,
      tables: tables,
    );
  }

  List<String> _parseTableRow(String line) {
    // Split on unescaped pipes, dropping the leading/trailing border pipes.
    final List<String> cells = <String>[];
    final StringBuffer cell = StringBuffer();
    int i = 0;
    // Skip the leading '|'.
    if (line.startsWith('|')) {
      i = 1;
    }
    while (i < line.length) {
      final String ch = line[i];
      if (ch == r'\' && i + 1 < line.length) {
        cell
          ..write(ch)
          ..write(line[i + 1]);
        i += 2;
        continue;
      }
      if (ch == '|') {
        cells.add(_unescape(cell.toString().trim()));
        cell.clear();
        i += 1;
        continue;
      }
      cell.write(ch);
      i += 1;
    }
    final String tail = cell.toString().trim();
    if (tail.isNotEmpty) {
      cells.add(_unescape(tail));
    }
    return cells;
  }
}
