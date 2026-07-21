/// How a goal's progress is determined (R-GOAL-004).
///
/// [manual] stores an explicit clamped `0..1` value. [derived] computes
/// progress from the goal's roadmap topics as weighted leaves; no other entity
/// (milestone, checklist item, linked task/note/resource) contributes, which
/// prevents double counting. Stored as a stable lowercase wire string.
enum GoalProgressMode {
  manual('manual'),
  derived('derived');

  const GoalProgressMode(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static GoalProgressMode fromWire(String wire) {
    for (final GoalProgressMode mode in GoalProgressMode.values) {
      if (mode.wire == wire) {
        return mode;
      }
    }
    throw FormatException('Unknown goal progress mode: $wire');
  }
}
