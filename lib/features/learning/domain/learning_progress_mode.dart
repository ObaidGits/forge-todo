/// How a Learning Resource's progress is determined (R-LEARN-004).
///
/// `derived` computes progress as completed eligible items divided by eligible
/// items. `manual` stores a user-entered fraction clamped to `0..1`. No mode
/// scrapes an external provider — provider scraping is explicitly out of scope
/// (R-LEARN-004).
enum LearningProgressMode {
  derived('derived'),
  manual('manual');

  const LearningProgressMode(this.wire);

  final String wire;

  static LearningProgressMode fromWire(String wire) {
    for (final LearningProgressMode mode in LearningProgressMode.values) {
      if (mode.wire == wire) {
        return mode;
      }
    }
    throw FormatException('Unknown LearningProgressMode "$wire".');
  }
}
