/// The base repetition unit of a recurrence rule (R-TASK-005).
///
/// This is the documented RFC-5545-compatible `FREQ` subset Forge supports:
/// daily, weekly, monthly, and yearly. Values persist as stable lowercase wire
/// strings with unknown-safe decoding.
enum RecurrenceFrequency {
  daily('daily'),
  weekly('weekly'),
  monthly('monthly'),
  yearly('yearly');

  const RecurrenceFrequency(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static RecurrenceFrequency fromWire(String wire) {
    for (final RecurrenceFrequency freq in RecurrenceFrequency.values) {
      if (freq.wire == wire) {
        return freq;
      }
    }
    throw FormatException('Unknown recurrence frequency: $wire');
  }
}
