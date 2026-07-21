/// The reorderable content sections of the Today screen (R-HOME-001,
/// R-HOME-002).
///
/// Quick capture is a pinned fast path and is intentionally *not* part of this
/// set: it always stays at the top of Today (ux-design §1, §8). Every other
/// current-release and progressive slot is listed here so the layout is
/// forward-compatible — sections whose feature has not shipped yet simply have
/// no content and collapse (R-HOME-002).
enum HomeSectionKind {
  /// Overdue tasks (urgent, past their due point).
  overdue('overdue'),

  /// Tasks scheduled or due today.
  todayTasks('today_tasks'),

  /// Today's habit occurrences (habits land Wave 6; empty until then).
  habits('habits'),

  /// Resume-learning recommendation (Learning lands Wave 5; empty until then).
  resumeLearning('resume_learning'),

  /// Active / next focus session (Focus lands Wave 6; empty until then).
  focus('focus'),

  /// Quick note capture slot (Notes lands Wave 4; empty until then).
  quickNote('quick_note'),

  /// Compact progress rings derived from the user's own records.
  progress('progress'),

  /// Completed-today tasks, hidden behind a count after a short celebration.
  completed('completed');

  const HomeSectionKind(this.wire);

  /// Stable persistence value used in the durable layout preference.
  final String wire;

  /// Decodes a stored [wire] value, or null when unknown (forward-compatible:
  /// an unknown persisted section is ignored rather than crashing).
  static HomeSectionKind? fromWireOrNull(String wire) {
    for (final HomeSectionKind kind in HomeSectionKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    return null;
  }
}
