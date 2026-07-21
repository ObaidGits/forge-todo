/// Whether a projected focus interval is active work or a pause (R-FOCUS-003).
///
/// Intervals are an immutable projection derived from the event log. A [work]
/// interval spans a running segment; a [pause] interval spans the gap between a
/// pause and the following resume/end. Only [work] intervals contribute to a
/// session's recorded duration and to the combined focus/study interval union
/// (R-FOCUS-005).
enum FocusIntervalKind {
  work('work'),
  pause('pause');

  const FocusIntervalKind(this.wire);

  final String wire;

  static FocusIntervalKind fromWire(String wire) {
    for (final FocusIntervalKind kind in FocusIntervalKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown focus interval kind: $wire');
  }
}
