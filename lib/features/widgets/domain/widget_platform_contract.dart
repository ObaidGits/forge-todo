/// The stable app <-> native widget-container contract (R-WIDGET-001/002/003).
///
/// This is the single source of truth for the string constants shared between
/// the Dart app and the native home-screen widgets (Android app widgets and the
/// iOS WidgetKit extension). The native code intentionally hard-codes the SAME
/// literals; changing a value here is a coordinated cross-platform change and
/// MUST be mirrored in:
///
///   * Android: `android/app/src/main/kotlin/app/forge/forge/widgets/`
///   * iOS:     `ios/ForgeWidgets/` and the Runner host plugin
///
/// Keeping the contract in one pure-Dart place lets Dart tests assert the
/// values the native side depends on, so a drift is caught in the fast test
/// tier rather than only on a device (testing.md §10).
library;

import 'package:forge/features/widgets/domain/widget_surface.dart';

/// The stable app <-> native widget contract.
abstract final class WidgetPlatformContract {
  /// The platform method channel the app uses to publish/clear snapshots to the
  /// native shared container. The native host handler listens on this name.
  static const String hostChannel = 'app.forge.forge/widget_host';

  /// Method: publish a canonical snapshot for one surface.
  /// Arguments: `{ 'surface': <wire>, 'payload': <canonical json> }`.
  static const String methodPublish = 'publish';

  /// Method: clear the snapshot for one surface.
  /// Arguments: `{ 'surface': <wire> }`.
  static const String methodClear = 'clear';

  /// Method: publish the shared bridge secret to the native container so it can
  /// sign outbound widget intents. Arguments: `{ 'secret': <string> }`.
  ///
  /// The secret is written to the same private shared storage the snapshots use
  /// and is never synced. Hardening this behind a platform keystore is tracked
  /// as a device follow-up (MANUAL-WIDGET-SECRET).
  static const String methodPublishSecret = 'publishSecret';

  /// The URI scheme every widget-originated deep link uses.
  static const String deepLinkScheme = 'forge';

  /// The URI host that namespaces all widget deep links.
  static const String deepLinkHost = 'widget';

  /// Path for an authenticated widget action (a tap that mutates data).
  static const String deepLinkActionPath = 'intent';

  /// Path for a plain "open this surface in the app" deep link (no mutation),
  /// e.g. tapping the Quick Note widget opens secure capture.
  static const String deepLinkOpenPath = 'open';

  /// Query parameter names, aligned with the intent canonical payload fields.
  static const String paramAction = 'action';
  static const String paramIntentId = 'intent_id';
  static const String paramIssuedAt = 'issued_at_utc_micros';
  static const String paramProfileId = 'profile_id';
  static const String paramSurface = 'surface';
  static const String paramTarget = 'target_entity_id';
  static const String paramToken = 'token';

  /// Storage key for a surface's canonical snapshot, shared with native.
  ///
  /// Android writes this key into the `forge_widgets` `SharedPreferences` file;
  /// iOS writes it into the app-group `UserDefaults` suite. The native readers
  /// use the identical key so a snapshot the app publishes is the snapshot the
  /// widget renders.
  static String snapshotStorageKey(WidgetSurface surface) =>
      'forge.widget.snapshot.${surface.wireName}';

  /// Storage key for the shared bridge secret.
  static const String secretStorageKey = 'forge.widget.secret';

  /// Android private SharedPreferences file backing the shared container.
  static const String androidPreferencesName = 'forge_widgets';

  /// iOS app-group identifier backing the shared container. The app and the
  /// widget extension must both declare this App Group entitlement (device
  /// follow-up MANUAL-WIDGET-IOS-APPGROUP).
  static const String iosAppGroup = 'group.app.forge.forge.widgets';
}
