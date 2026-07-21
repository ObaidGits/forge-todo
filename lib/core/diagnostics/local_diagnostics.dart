import 'dart:collection';
import 'dart:convert';

import 'package:forge/core/security/redacting_log.dart';

enum DiagnosticMetric {
  migrationDurationMs,
  databaseSizeBytes,
  queryLatencyMs,
  outboxDepth,
  widgetSnapshotAgeMs,
}

enum DiagnosticSubsystem { sync, notificationReconciliation }

enum DiagnosticState { idle, running, succeeded, degraded, failed, unavailable }

final class DiagnosticEntry {
  const DiagnosticEntry._({
    required this.occurredAt,
    required this.name,
    required this.value,
  });

  final DateTime occurredAt;
  final String name;
  final Object value;

  Map<String, Object> toJson() => <String, Object>{
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'name': name,
    'value': value,
  };
}

/// A process-local diagnostics recorder with a fixed, content-free vocabulary.
final class LocalDiagnostics {
  LocalDiagnostics({
    required this.utcNow,
    required this.logBuffer,
    this.capacity = 200,
  }) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive.');
    }
  }

  static const int schemaVersion = 1;

  final UtcNow utcNow;
  final LocalLogBuffer logBuffer;
  final int capacity;
  final List<DiagnosticEntry> _entries = <DiagnosticEntry>[];
  List<DiagnosticEntry> get entries =>
      UnmodifiableListView<DiagnosticEntry>(_entries);

  void recordMeasurement(DiagnosticMetric metric, num value) {
    if (value.isNegative || !value.isFinite) {
      throw ArgumentError.value(
        value,
        'value',
        'Must be finite and nonnegative.',
      );
    }
    _add(
      DiagnosticEntry._(
        occurredAt: utcNow().toUtc(),
        name: metric.name,
        value: value,
      ),
    );
  }

  void recordState(DiagnosticSubsystem subsystem, DiagnosticState state) {
    _add(
      DiagnosticEntry._(
        occurredAt: utcNow().toUtc(),
        name: subsystem.name,
        value: state.name,
      ),
    );
  }

  DiagnosticsExportPreview prepareExport() {
    final DateTime generatedAt = utcNow().toUtc();
    final Map<String, Object> payload = <String, Object>{
      'schema_version': schemaVersion,
      'generated_at': generatedAt.toIso8601String(),
      'diagnostics': _entries
          .map((DiagnosticEntry entry) => entry.toJson())
          .toList(growable: false),
      'logs': logBuffer.records
          .map((StructuredLogRecord record) => record.toJson())
          .toList(growable: false),
    };
    final String contents = const JsonEncoder.withIndent('  ').convert(payload);
    return DiagnosticsExportPreview._(
      generatedAt: generatedAt,
      contents: contents,
    );
  }

  DiagnosticsExport export(
    DiagnosticsExportPreview preview, {
    required bool userConsented,
  }) {
    if (!userConsented) {
      throw StateError('Diagnostics export requires explicit user consent.');
    }
    return DiagnosticsExport._(
      generatedAt: preview.generatedAt,
      bytes: utf8.encode(preview.contents),
    );
  }

  void clear() {
    _entries.clear();
    logBuffer.clear();
  }

  void _add(DiagnosticEntry entry) {
    if (_entries.length == capacity) {
      _entries.removeAt(0);
    }
    _entries.add(entry);
  }
}

/// Exact local payload shown before the user decides whether to export it.
final class DiagnosticsExportPreview {
  const DiagnosticsExportPreview._({
    required this.generatedAt,
    required this.contents,
  });

  final DateTime generatedAt;
  final String contents;

  int get byteLength => utf8.encode(contents).length;
}

/// Bytes created after consent. Transmission is deliberately outside this API.
final class DiagnosticsExport {
  DiagnosticsExport._({required this.generatedAt, required List<int> bytes})
    : bytes = List<int>.unmodifiable(bytes);

  final DateTime generatedAt;
  final List<int> bytes;
}
