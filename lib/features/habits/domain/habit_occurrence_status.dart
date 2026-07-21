/// The current status projection of a materialized habit occurrence
/// (R-HABIT-003, R-HABIT-004, R-HABIT-007).
///
/// The projection is derived from the append-only check-in log and the
/// occurrence's close state; it is a convenience column, never the source of
/// truth. A paused occurrence is tracked separately by a boolean flag because
/// pause makes an occurrence ineligible for streak and consistency without
/// changing whether its target was met (R-HABIT-004).
enum HabitOccurrenceStatus {
  /// Not yet complete and not yet closed (or closed abstinence with no
  /// violation is instead [completed]).
  open('open'),

  /// The target was met (numeric total reached, boolean true, or an abstinence
  /// period closed with no violation).
  completed('completed'),

  /// The period closed without the target being met, or an abstinence
  /// violation was recorded.
  missed('missed'),

  /// The user explicitly skipped this occurrence with a reason. A skip stays in
  /// the consistency denominator but never completes or increments the streak,
  /// and is neutral for streak continuity (R-HABIT-004, R-HABIT-007).
  skipped('skipped');

  const HabitOccurrenceStatus(this.wire);

  final String wire;

  static HabitOccurrenceStatus fromWire(String wire) {
    for (final HabitOccurrenceStatus status in HabitOccurrenceStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown habit occurrence status: $wire');
  }
}
