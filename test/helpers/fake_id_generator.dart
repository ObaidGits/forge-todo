import 'package:forge/core/domain/id.dart';

/// Deterministic UUIDv7-shaped values for tests. Sequence exhaustion is an
/// error so a test cannot silently begin using random identity.
final class FakeIdGenerator implements IdGenerator {
  FakeIdGenerator([Iterable<String>? values])
    : _values = List<String>.unmodifiable(
        (values ?? const <String>[]).map(_validateUuidV7),
      );

  FakeIdGenerator.sequential({int start = 1})
    : _values = const <String>[],
      _nextSequence = _validateSequence(start);

  static const int _maxSequence = 0xffffffffffff;
  static final RegExp _uuidV7Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final List<String> _values;
  int _index = 0;
  int? _nextSequence;

  int get generatedCount => _index;

  @override
  String uuidV7() {
    final int? sequence = _nextSequence;
    final String value;
    if (sequence != null) {
      if (sequence > _maxSequence) {
        throw StateError('Fake sequential UUIDv7 range exhausted.');
      }
      value = _uuidFor(sequence);
      _nextSequence = sequence + 1;
    } else {
      if (_index >= _values.length) {
        throw StateError('Fake ID sequence exhausted.');
      }
      value = _values[_index];
    }
    _index += 1;
    return value;
  }

  static int _validateSequence(int value) {
    if (value < 0 || value > _maxSequence) {
      throw ArgumentError.value(
        value,
        'start',
        'Must fit the 48-bit deterministic UUIDv7 sequence.',
      );
    }
    return value;
  }

  static String _validateUuidV7(String value) {
    if (!_uuidV7Pattern.hasMatch(value)) {
      throw FormatException('Invalid lowercase RFC 9562 UUIDv7: $value');
    }
    return value;
  }

  static String _uuidFor(int sequence) {
    final String suffix = sequence.toRadixString(16).padLeft(12, '0');
    return '018f0000-0000-7000-8000-$suffix';
  }
}
