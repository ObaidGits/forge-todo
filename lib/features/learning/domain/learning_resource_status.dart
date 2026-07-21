/// Lifecycle status of a Learning Resource (R-LEARN-001).
///
/// Status is a user-controlled label independent of derived progress: a user
/// MAY archive a resource with incomplete items, or mark it completed while the
/// derived fraction is below 1. Archiving preserves all items, sessions, and
/// history (mirrors goal archive behaviour).
enum LearningResourceStatus {
  active('active'),
  completed('completed'),
  onHold('on_hold'),
  archived('archived');

  const LearningResourceStatus(this.wire);

  final String wire;

  static LearningResourceStatus fromWire(String wire) {
    for (final LearningResourceStatus status in LearningResourceStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown LearningResourceStatus "$wire".');
  }
}
