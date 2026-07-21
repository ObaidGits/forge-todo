import 'dart:collection';

enum LogLevel { debug, info, warning, error }

enum LogDataClass {
  operational,
  userContent,
  credential,
  secretUrl,
  externalPath,
  sensitiveMetadata,
}

/// A value offered to structured logging.
///
/// Values are sensitive unless the caller explicitly classifies them as
/// operational. Even operational values pass through the redactor.
final class LogAttribute {
  const LogAttribute(Object? value)
    : this._(value, LogDataClass.sensitiveMetadata);

  const LogAttribute.operational(Object? value)
    : this._(value, LogDataClass.operational);

  const LogAttribute.userContent(Object? value)
    : this._(value, LogDataClass.userContent);

  const LogAttribute.credential(Object? value)
    : this._(value, LogDataClass.credential);

  const LogAttribute.secretUrl(Object? value)
    : this._(value, LogDataClass.secretUrl);

  const LogAttribute.externalPath(Object? value)
    : this._(value, LogDataClass.externalPath);

  const LogAttribute.sensitiveMetadata(Object? value)
    : this._(value, LogDataClass.sensitiveMetadata);

  const LogAttribute._(this._value, this.dataClass);

  final Object? _value;
  final LogDataClass dataClass;

  @override
  String toString() => LogRedactor.redactedValue;
}

/// Immutable, already-redacted event accepted by local sinks.
final class StructuredLogRecord {
  StructuredLogRecord({
    required this.occurredAt,
    required this.level,
    required this.component,
    required this.eventCode,
    required Map<String, Object?> attributes,
  }) : attributes = UnmodifiableMapView<String, Object?>(
         Map<String, Object?>.of(attributes),
       );

  final DateTime occurredAt;
  final LogLevel level;
  final String component;
  final String eventCode;
  final Map<String, Object?> attributes;

  Map<String, Object?> toJson() => <String, Object?>{
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'level': level.name,
    'component': component,
    'event_code': eventCode,
    'attributes': attributes,
  };
}

/// Marker contract for process-local log destinations only.
abstract interface class LocalLogSink {
  void write(StructuredLogRecord record);
}

/// Bounded process-local history used by diagnostics. Oldest events are
/// discarded first so logging cannot grow memory without limit.
final class LocalLogBuffer implements LocalLogSink {
  LocalLogBuffer({this.capacity = 200}) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive.');
    }
  }

  final int capacity;
  final List<StructuredLogRecord> _records = <StructuredLogRecord>[];

  List<StructuredLogRecord> get records =>
      List<StructuredLogRecord>.unmodifiable(_records);

  @override
  void write(StructuredLogRecord record) {
    if (_records.length == capacity) {
      _records.removeAt(0);
    }
    _records.add(record);
  }

  void clear() => _records.clear();
}

final class LogRedactor {
  const LogRedactor();

  static const String redactedValue = '[redacted]';

  static final RegExp _sensitiveKey = RegExp(
    r'(^|_)(body|content|description|email|name|note|password|path|query|search|secret|title|token|uri|url)($|_)|(^|_)(profile|user|device|entity|record|command)_?id($|_)',
    caseSensitive: false,
  );
  static final RegExp _safeOperationalText = RegExp(r'^[a-zA-Z0-9_.:-]{1,80}$');
  static final RegExp _bearerOrJwt = RegExp(
    r'(^|\s)bearer\s+|^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$',
    caseSensitive: false,
  );
  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Map<String, Object?> redact(Map<String, LogAttribute> attributes) {
    final Map<String, Object?> safe = <String, Object?>{};
    for (final MapEntry<String, LogAttribute> entry in attributes.entries) {
      final LogAttribute attribute = entry.value;
      if (attribute.dataClass != LogDataClass.operational ||
          _sensitiveKey.hasMatch(entry.key)) {
        safe[entry.key] = redactedValue;
      } else {
        safe[entry.key] = redactOperational(attribute._value);
      }
    }
    return safe;
  }

  Object? redactOperational(Object? value) {
    if (value == null || value is bool || value is int) {
      return value;
    }
    if (value is double) {
      return value.isFinite ? value : redactedValue;
    }
    if (value is String &&
        _safeOperationalText.hasMatch(value) &&
        !_bearerOrJwt.hasMatch(value) &&
        !_uuid.hasMatch(value)) {
      return value;
    }
    return redactedValue;
  }

  String redactLabel(String value) {
    final Object? redacted = redactOperational(value);
    return redacted is String ? redacted : redactedValue;
  }
}

typedef UtcNow = DateTime Function();

/// Emits allowlisted structured events exclusively to local sinks.
final class StructuredLogger {
  StructuredLogger({
    required this.utcNow,
    required Iterable<LocalLogSink> sinks,
    this.minimumLevel = LogLevel.info,
    this.redactor = const _DefaultLogRedactor(),
  }) : _sinks = List<LocalLogSink>.unmodifiable(sinks);

  final UtcNow utcNow;
  final List<LocalLogSink> _sinks;
  final LogLevel minimumLevel;
  final LogRedactor redactor;

  void log({
    required LogLevel level,
    required String component,
    required String eventCode,
    Map<String, LogAttribute> attributes = const <String, LogAttribute>{},
  }) {
    if (level.index < minimumLevel.index) {
      return;
    }
    final StructuredLogRecord record = StructuredLogRecord(
      occurredAt: utcNow().toUtc(),
      level: level,
      component: redactor.redactLabel(component),
      eventCode: redactor.redactLabel(eventCode),
      attributes: redactor.redact(attributes),
    );
    for (final LocalLogSink sink in _sinks) {
      sink.write(record);
    }
  }
}

/// Const default retained only to keep logger construction lightweight.
final class _DefaultLogRedactor extends LogRedactor {
  const _DefaultLogRedactor();
}
