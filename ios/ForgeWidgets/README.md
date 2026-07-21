# Forge WidgetKit extension

The iOS home-screen widgets for the five V1 surfaces (R-WIDGET-001): Today
Tasks, Habit Checklist, Quick Note, Study/Focus countdown, Roadmap Progress.

These sources render ONLY from the redacted, versioned snapshot the app writes
into the shared App Group container (R-WIDGET-002); they never open the
encrypted database. Taps build a signed `forge://widget/intent` deep link that
the Dart bridge verifies before any command runs (R-WIDGET-003), and the views
honour redacted/stale state honestly (R-WIDGET-003/004).

## Files

- `ForgeWidgetsContract.swift` — mirror of the Dart `WidgetPlatformContract`.
- `WidgetSnapshot.swift` — Codable snapshot model + version-safe App Group load.
- `WidgetIntentSigner.swift` — mirror of the keyed-hash intent signer.
- `WidgetDeepLinks.swift` — builds the `forge://widget/...` links.
- `ForgeWidgetProvider.swift` — `TimelineProvider` reading the snapshot.
- `ForgeWidgetViews.swift` — shared SwiftUI rendering (sizes/families).
- `ForgeWidgetBundle.swift` — `@main` bundle with the five widgets.
- `Info.plist`, `ForgeWidgets.entitlements` — extension config + App Group.

## Manual Xcode wiring (device/CI follow-ups)

These cannot be done from the Flutter/Dart toolchain and must be completed in
Xcode on a machine with the iOS SDK:

- **MANUAL-WIDGET-IOS-TARGET** — add a "Widget Extension" target named
  `ForgeWidgets`, set its sources to this folder, embed it in the Runner app.
- **MANUAL-WIDGET-IOS-APPGROUP** — enable the App Group
  `group.app.forge.forge.widgets` on BOTH the Runner and the extension targets
  (the Runner uses `ios/Runner/Runner.entitlements`).
- **MANUAL-WIDGET-IOS-RENDER** — run WidgetKit snapshot/UI tests on a simulator
  and a physical device for each family, locked-privacy, stale, and deep-link
  cases (task 11.4).
