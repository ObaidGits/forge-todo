/// Roadmap topic status (R-GOAL-003, R-GOAL-004).
///
/// Topics are the only weighted progress leaves of a roadmap (R-GOAL-004).
/// Status drives both eligibility and completion for the derived progress
/// policy:
///
/// * [open] / [inProgress] — eligible, not yet completed.
/// * [completed] — eligible and contributes its nonnegative weight.
/// * [archived] / [cancelled] — ineligible; excluded from progress entirely so
///   an abandoned topic neither inflates nor deflates the denominator.
///
/// Stored as a stable lowercase wire string with unknown-safe decoding.
enum RoadmapTopicStatus {
  open('open'),
  inProgress('in_progress'),
  completed('completed'),
  archived('archived'),
  cancelled('cancelled');

  const RoadmapTopicStatus(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static RoadmapTopicStatus fromWire(String wire) {
    for (final RoadmapTopicStatus status in RoadmapTopicStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown roadmap topic status: $wire');
  }

  /// True when the topic contributes to derived progress (R-GOAL-004): every
  /// status except [archived] and [cancelled].
  bool get isEligible =>
      this != RoadmapTopicStatus.archived &&
      this != RoadmapTopicStatus.cancelled;

  /// True when the topic is complete and contributes its weight to the
  /// numerator (R-GOAL-004).
  bool get isCompleted => this == RoadmapTopicStatus.completed;
}
