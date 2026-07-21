/// Roadmap lifecycle status (R-GOAL-003).
///
/// A roadmap details a single goal (R-GOAL-001). Status is a coarse lifecycle
/// marker stored as a stable lowercase wire string with unknown-safe decoding.
/// It is orthogonal to the derived progress computed from the roadmap's topics
/// (R-GOAL-004): a roadmap may be `active` while incomplete, marked `completed`
/// when the user considers it done, or `archived` to preserve history without
/// cluttering active views.
enum RoadmapStatus {
  active('active'),
  completed('completed'),
  archived('archived');

  const RoadmapStatus(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value. Throws [FormatException] for an unknown
  /// value so corrupt persistence is surfaced rather than silently coerced.
  static RoadmapStatus fromWire(String wire) {
    for (final RoadmapStatus status in RoadmapStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown roadmap status: $wire');
  }
}
