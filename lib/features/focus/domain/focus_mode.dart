/// How a focus session measures its planned length (R-FOCUS-001).
///
/// A [countUp] session runs open-ended and simply accumulates elapsed work
/// time. An [interval] session is configured with a planned duration (a Deep
/// Work / Pomodoro style block); the planned length is advisory truth for the
/// UI and never a substitute for the recorded elapsed time.
///
/// Stored as a stable lowercase wire string with unknown-safe decoding.
enum FocusMode {
  countUp('count_up'),
  interval('interval');

  const FocusMode(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] on an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static FocusMode fromWire(String wire) {
    for (final FocusMode mode in FocusMode.values) {
      if (mode.wire == wire) {
        return mode;
      }
    }
    throw FormatException('Unknown focus mode: $wire');
  }
}
