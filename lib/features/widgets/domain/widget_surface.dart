/// The home-screen widget surfaces Forge can render (R-WIDGET-001).
///
/// A surface is the stable, non-sensitive discriminator shared between the app
/// and the native widget container. It appears in redacted snapshots and in
/// widget-originated intents, so it is deliberately an opaque enum with stable
/// wire names and unknown-safe decoding.
library;

enum WidgetSurface {
  /// Today's overdue/today tasks.
  todayTasks('today_tasks'),

  /// Today's habit occurrences with check state.
  habitChecklist('habit_checklist'),

  /// The most recent quick note.
  quickNote('quick_note'),

  /// A running or next study/focus countdown.
  studyFocusCountdown('study_focus_countdown'),

  /// Roadmap progress for a pinned goal.
  roadmapProgress('roadmap_progress');

  const WidgetSurface(this.wireName);

  /// Stable lowercase wire name used in the shared container and intents.
  final String wireName;

  /// Decodes [wireName] with unknown-safe behavior: an unrecognized value
  /// returns null rather than throwing, so a newer container format never
  /// crashes an older reader (data-model §Boolean/enum unknown-safe decoding).
  static WidgetSurface? fromWire(String? wireName) {
    if (wireName == null) {
      return null;
    }
    for (final WidgetSurface surface in WidgetSurface.values) {
      if (surface.wireName == wireName) {
        return surface;
      }
    }
    return null;
  }
}
