/// Task lifecycle status (R-TASK-003).
///
/// Stored as a stable lowercase wire string with unknown-safe decoding. A task
/// is terminal when it is [completed] or [cancelled]; terminal tasks are never
/// overdue (R-TASK-004).
enum TaskStatus {
  open('open'),
  inProgress('in_progress'),
  completed('completed'),
  cancelled('cancelled');

  const TaskStatus(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static TaskStatus fromWire(String wire) {
    for (final TaskStatus status in TaskStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown task status: $wire');
  }

  /// True when the status is a terminal (completed or cancelled) state.
  bool get isTerminal =>
      this == TaskStatus.completed || this == TaskStatus.cancelled;

  /// True when the task is still actionable (open or in progress).
  bool get isActive => this == TaskStatus.open || this == TaskStatus.inProgress;
}
