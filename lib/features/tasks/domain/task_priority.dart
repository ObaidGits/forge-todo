/// Task priority (R-TASK-003).
///
/// Stored as a stable lowercase wire string. [rank] gives a stable numeric
/// ordering (urgent highest) for sort keys that cannot rely on the text value.
enum TaskPriority {
  none('none', 0),
  low('low', 1),
  medium('medium', 2),
  high('high', 3),
  urgent('urgent', 4);

  const TaskPriority(this.wire, this.rank);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Higher means more urgent. Used for deterministic ordering.
  final int rank;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value.
  static TaskPriority fromWire(String wire) {
    for (final TaskPriority priority in TaskPriority.values) {
      if (priority.wire == wire) {
        return priority;
      }
    }
    throw FormatException('Unknown task priority: $wire');
  }
}
