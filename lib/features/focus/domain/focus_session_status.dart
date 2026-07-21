/// The visible status projection of a focus session (R-FOCUS-003).
///
/// The status is a projection derived from the immutable event log, persisted
/// on the session row for cheap reads and the one-open-per-profile constraint.
/// A session is *open* while [running] or [paused] and *terminal* once
/// [completed] or [cancelled]. At most one open session may exist per profile.
///
/// Stored as a stable lowercase wire string with unknown-safe decoding.
enum FocusSessionStatus {
  running('running'),
  paused('paused'),
  completed('completed'),
  cancelled('cancelled');

  const FocusSessionStatus(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  static FocusSessionStatus fromWire(String wire) {
    for (final FocusSessionStatus status in FocusSessionStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown focus session status: $wire');
  }

  /// True while the session is still open (running or paused).
  bool get isOpen =>
      this == FocusSessionStatus.running || this == FocusSessionStatus.paused;

  /// True once the session has reached a terminal state.
  bool get isTerminal =>
      this == FocusSessionStatus.completed ||
      this == FocusSessionStatus.cancelled;
}
