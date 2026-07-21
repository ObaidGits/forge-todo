/// Goal lifecycle status (R-GOAL-002).
///
/// Stored as a stable lowercase wire string with unknown-safe decoding. Status
/// is orthogonal to archival: an archived goal preserves its status and all
/// history (R-GOAL-007). `achieved` is the terminal success state, `abandoned`
/// the terminal give-up state; `active` and `onHold` are in-flight.
enum GoalStatus {
  active('active'),
  onHold('on_hold'),
  achieved('achieved'),
  abandoned('abandoned');

  const GoalStatus(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static GoalStatus fromWire(String wire) {
    for (final GoalStatus status in GoalStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown goal status: $wire');
  }

  /// True when the goal reached a terminal outcome (achieved or abandoned).
  bool get isTerminal =>
      this == GoalStatus.achieved || this == GoalStatus.abandoned;
}
