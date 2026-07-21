import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/diagnostics/local_diagnostics.dart';
import 'package:forge/core/security/redacting_log.dart';

final DateTime _now = DateTime.utc(2026, 2, 4, 6, 8, 10);

void main() {
  // **Validates: Requirements R-SEC-004, NFR-SEC-003**
  test('preview contains only allowlisted diagnostics and redacted logs', () {
    final LocalLogBuffer buffer = LocalLogBuffer();
    final StructuredLogger logger = StructuredLogger(
      utcNow: () => _now,
      sinks: <LocalLogSink>[buffer],
    );
    final LocalDiagnostics diagnostics = LocalDiagnostics(
      utcNow: () => _now,
      logBuffer: buffer,
    );

    logger.log(
      level: LogLevel.error,
      component: 'database',
      eventCode: 'open.failed',
      attributes: const <String, LogAttribute>{
        'duration_ms': LogAttribute.operational(18),
        'note': LogAttribute.userContent('my private journal'),
        'database_path': LogAttribute.externalPath('/home/me/forge.db'),
      },
    );
    diagnostics.recordMeasurement(DiagnosticMetric.databaseSizeBytes, 4096);
    diagnostics.recordState(
      DiagnosticSubsystem.notificationReconciliation,
      DiagnosticState.degraded,
    );

    final DiagnosticsExportPreview preview = diagnostics.prepareExport();
    expect(preview.contents, contains('databaseSizeBytes'));
    expect(preview.contents, contains('notificationReconciliation'));
    expect(preview.contents, contains(LogRedactor.redactedValue));
    expect(preview.contents, isNot(contains('my private journal')));
    expect(preview.contents, isNot(contains('/home/me/forge.db')));
    expect(preview.byteLength, utf8.encode(preview.contents).length);
  });
  test(
    'export requires explicit consent and preserves the previewed bytes',
    () {
      final LocalDiagnostics diagnostics = LocalDiagnostics(
        utcNow: () => _now,
        logBuffer: LocalLogBuffer(),
      )..recordMeasurement(DiagnosticMetric.outboxDepth, 3);
      final DiagnosticsExportPreview preview = diagnostics.prepareExport();

      expect(
        () => diagnostics.export(preview, userConsented: false),
        throwsStateError,
      );

      final DiagnosticsExport export = diagnostics.export(
        preview,
        userConsented: true,
      );
      expect(utf8.decode(export.bytes), preview.contents);
      expect(export.generatedAt, preview.generatedAt);
    },
  );

  test('diagnostics reject invalid measurements and bound local history', () {
    final LocalDiagnostics diagnostics = LocalDiagnostics(
      utcNow: () => _now,
      logBuffer: LocalLogBuffer(),
      capacity: 2,
    );

    expect(
      () => diagnostics.recordMeasurement(DiagnosticMetric.queryLatencyMs, -1),
      throwsArgumentError,
    );
    expect(
      () => diagnostics.recordMeasurement(
        DiagnosticMetric.queryLatencyMs,
        double.nan,
      ),
      throwsArgumentError,
    );

    diagnostics
      ..recordMeasurement(DiagnosticMetric.queryLatencyMs, 1)
      ..recordMeasurement(DiagnosticMetric.queryLatencyMs, 2)
      ..recordMeasurement(DiagnosticMetric.queryLatencyMs, 3);

    expect(diagnostics.entries, hasLength(2));
    final Map<String, Object?> payload =
        jsonDecode(diagnostics.prepareExport().contents)
            as Map<String, Object?>;
    expect(payload.keys, <String>{
      'schema_version',
      'generated_at',
      'diagnostics',
      'logs',
    });
  });
}
