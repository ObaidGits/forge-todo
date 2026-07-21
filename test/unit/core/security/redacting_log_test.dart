import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/redacting_log.dart';

final DateTime _now = DateTime.utc(2026, 1, 2, 3, 4, 5);

StructuredLogger _logger(
  LocalLogBuffer buffer, {
  LogLevel minimumLevel = LogLevel.debug,
}) {
  return StructuredLogger(
    utcNow: () => _now,
    sinks: <LocalLogSink>[buffer],
    minimumLevel: minimumLevel,
  );
}

void main() {
  // **Validates: Requirements R-SEC-004, NFR-SEC-003**
  test('sensitive attributes are redacted while operational values remain', () {
    final LocalLogBuffer buffer = LocalLogBuffer();

    _logger(buffer).log(
      level: LogLevel.info,
      component: 'database',
      eventCode: 'query.completed',
      attributes: const <String, LogAttribute>{
        'duration_ms': LogAttribute.operational(12),
        'phase': LogAttribute.operational('opening'),
        'body': LogAttribute.operational('private-note'),
        'token': LogAttribute.credential('Bearer abc.def.ghi'),
        'path': LogAttribute.externalPath('/home/person/forge.db'),
        'default_private': LogAttribute('user words'),
      },
    );

    final StructuredLogRecord record = buffer.records.single;
    expect(record.attributes['duration_ms'], 12);
    expect(record.attributes['phase'], 'opening');
    expect(record.attributes['body'], LogRedactor.redactedValue);
    expect(record.attributes['token'], LogRedactor.redactedValue);
    expect(record.attributes['path'], LogRedactor.redactedValue);
    expect(record.attributes['default_private'], LogRedactor.redactedValue);
  });
  test('defense-in-depth redacts unsafe values marked operational', () {
    final LocalLogBuffer buffer = LocalLogBuffer();
    const List<String> unsafeValues = <String>[
      'https://example.test/reset?token=secret',
      '/Users/person/Documents/forge.db',
      r'C:\Users\person\forge.db',
      'Bearer abcdefghijklmnopqrstuvwxyz',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.abcdefghijklmnop',
      'private words with spaces',
      '550e8400-e29b-41d4-a716-446655440000',
    ];

    _logger(buffer).log(
      level: LogLevel.warning,
      component: 'sync',
      eventCode: 'sync.failed',
      attributes: <String, LogAttribute>{
        for (int index = 0; index < unsafeValues.length; index++)
          'value_$index': LogAttribute.operational(unsafeValues[index]),
      },
    );

    final String encoded = jsonEncode(buffer.records.single.toJson());
    for (final String unsafe in unsafeValues) {
      expect(encoded, isNot(contains(unsafe)));
    }
    expect(
      buffer.records.single.attributes.values,
      everyElement(LogRedactor.redactedValue),
    );
  });

  test(
    'local buffer is bounded and verbose logging is disabled by default',
    () {
      final LocalLogBuffer buffer = LocalLogBuffer(capacity: 2);
      final StructuredLogger logger = StructuredLogger(
        utcNow: () => _now,
        sinks: <LocalLogSink>[buffer],
      );

      logger.log(
        level: LogLevel.debug,
        component: 'app',
        eventCode: 'verbose.event',
      );
      for (int index = 0; index < 3; index++) {
        logger.log(
          level: LogLevel.info,
          component: 'app',
          eventCode: 'event.$index',
        );
      }

      expect(buffer.records, hasLength(2));
      expect(
        buffer.records.map((StructuredLogRecord event) => event.eventCode),
        <String>['event.1', 'event.2'],
      );
    },
  );
  test('generated user content never survives structured serialization', () {
    final Random random = Random(2404);
    final LocalLogBuffer buffer = LocalLogBuffer(capacity: 300);
    final StructuredLogger logger = _logger(buffer);
    final List<String> generated = <String>[];

    for (int sample = 0; sample < 200; sample++) {
      final String value = List<String>.generate(
        24,
        (int index) => String.fromCharCode(33 + random.nextInt(90)),
      ).join();
      generated.add(value);
      logger.log(
        level: LogLevel.info,
        component: 'property',
        eventCode: 'sample.$sample',
        attributes: <String, LogAttribute>{
          'candidate': LogAttribute.userContent(value),
        },
      );
    }

    final String encoded = jsonEncode(
      buffer.records
          .map((StructuredLogRecord record) => record.toJson())
          .toList(),
    );
    for (final String value in generated) {
      expect(encoded, isNot(contains(value)));
    }
  });
}
