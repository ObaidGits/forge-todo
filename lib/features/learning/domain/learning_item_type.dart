/// The kind of an ordered item inside a Learning Resource (R-LEARN-001).
///
/// A `section` is a structural container (a module/chapter grouping) and is NOT
/// an eligible progress leaf; every other type is an eligible leaf that counts
/// toward derived progress (R-LEARN-004). Keeping eligibility a pure function of
/// the type — rather than a separately stored flag — makes the progress formula
/// transparent and reproducible.
enum LearningItemType {
  section('section', eligibleLeaf: false),
  lesson('lesson', eligibleLeaf: true),
  video('video', eligibleLeaf: true),
  chapter('chapter', eligibleLeaf: true),
  article('article', eligibleLeaf: true),
  exercise('exercise', eligibleLeaf: true),
  other('other', eligibleLeaf: true);

  const LearningItemType(this.wire, {required this.eligibleLeaf});

  final String wire;

  /// Whether items of this type count as eligible progress leaves.
  final bool eligibleLeaf;

  static LearningItemType fromWire(String wire) {
    for (final LearningItemType type in LearningItemType.values) {
      if (type.wire == wire) {
        return type;
      }
    }
    throw FormatException('Unknown LearningItemType "$wire".');
  }
}
