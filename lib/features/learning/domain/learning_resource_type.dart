/// The user-facing kind of a Learning Resource (R-LEARN-001).
///
/// Forge presents these as a single "Learning Resource" umbrella; the internal
/// schema retains the `course` table name but this taxonomy is never surfaced
/// to the user as "course" specifically — `course` is one type among several.
enum LearningResourceType {
  course('course'),
  book('book'),
  playlist('playlist'),
  article('article'),
  other('other');

  const LearningResourceType(this.wire);

  /// The stable lowercase wire/storage value.
  final String wire;

  static LearningResourceType fromWire(String wire) {
    for (final LearningResourceType type in LearningResourceType.values) {
      if (type.wire == wire) {
        return type;
      }
    }
    throw FormatException('Unknown LearningResourceType "$wire".');
  }
}
