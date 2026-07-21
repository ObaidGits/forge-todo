import 'package:forge/features/focus/domain/focus_mode.dart';

/// A named starting configuration for a focus session (R-FOCUS-004).
///
/// A preset is **not** a separate data model: it is a convenience that resolves
/// to an ordinary [FocusMode] plus, for interval presets, a planned duration.
/// "Deep Work" is therefore just a preset over the same `focus_sessions` shape,
/// never a distinct entity type. The chosen preset name MAY be persisted on the
/// session purely as provenance; it carries no behaviour of its own.
enum FocusPreset {
  /// Open-ended count-up stopwatch.
  freeform('freeform', FocusMode.countUp, null),

  /// A long uninterrupted deep-work block (90 minutes).
  deepWork('deep_work', FocusMode.interval, Duration(minutes: 90)),

  /// A classic 25-minute Pomodoro block.
  pomodoro('pomodoro', FocusMode.interval, Duration(minutes: 25)),

  /// A short 5-minute break block.
  shortBreak('short_break', FocusMode.interval, Duration(minutes: 5));

  const FocusPreset(this.wire, this.mode, this._plannedDuration);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// The mode the preset resolves to.
  final FocusMode mode;

  final Duration? _plannedDuration;

  /// The planned duration for an interval preset, or null for a count-up
  /// preset. Always positive when present.
  Duration? get plannedDuration => _plannedDuration;

  /// The planned duration in whole seconds, or null for a count-up preset.
  int? get plannedDurationSec => _plannedDuration?.inSeconds;

  static FocusPreset fromWire(String wire) {
    for (final FocusPreset preset in FocusPreset.values) {
      if (preset.wire == wire) {
        return preset;
      }
    }
    throw FormatException('Unknown focus preset: $wire');
  }
}
