import 'package:forge/core/domain/id.dart';

/// The optional water-tracking preference (R-FIT-003).
///
/// Water tracking is optional and disabled by default. This is a local,
/// per-profile device preference — not sync-eligible domain data — so it is
/// read and written directly against the active local generation rather than
/// through the command bus. While it is disabled (the default), no water event
/// can be logged and no water UI should surface; the underlying
/// `water_events` history is preserved regardless of the toggle so re-enabling
/// never loses past records.
abstract interface class WaterTrackingSettings {
  /// Whether water tracking is currently enabled for [profileId]. Defaults to
  /// `false` when no preference has been stored (R-FIT-003).
  Future<bool> isEnabled(ProfileId profileId);

  /// Enables or disables water tracking for [profileId]. Disabling never
  /// deletes existing water history.
  Future<void> setEnabled(ProfileId profileId, {required bool enabled});
}
