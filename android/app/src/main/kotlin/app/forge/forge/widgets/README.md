# Android home-screen widgets

The Android app widgets for the five V1 surfaces (R-WIDGET-001): Today Tasks,
Habit Checklist, Quick Note, Study/Focus countdown, Roadmap Progress.

Each provider renders ONLY from the redacted, versioned snapshot the app writes
into the private `forge_widgets` SharedPreferences container (R-WIDGET-002); it
never opens the encrypted database. Taps build a signed `forge://widget/intent`
deep link that the Dart bridge verifies before any command runs (R-WIDGET-003),
and the layouts honour redacted/stale state honestly (R-WIDGET-003/004).

## Files

- `WidgetContract.kt` — mirror of the Dart `WidgetPlatformContract`.
- `WidgetSnapshot.kt` — snapshot model + version-safe JSON decode.
- `WidgetSharedStorage.kt` — the local-only SharedPreferences container.
- `WidgetIntentSigner.kt` — mirror of the keyed-hash intent signer.
- `WidgetDeepLinks.kt` — builds the `forge://widget/...` links.
- `ForgeAppWidgetProvider.kt` — shared rendering base (redaction/stale/rows).
- `SurfaceWidgetProviders.kt` — the five per-surface providers.
- `ForgeWidgetHostPlugin.kt` — the method-channel host that applies publishes.

Sizes are declared per provider in `res/xml/widget_*_info.xml` (Quick Note and
Study/Focus small; Today Tasks and Habit Checklist medium; Roadmap large).

## Device/CI follow-ups

- **MANUAL-WIDGET-ANDROID-RENDER** — run app-widget instrumentation on
  min/mid/latest emulators and a physical device for sizes, locked-privacy,
  stale snapshot, deep links, and check actions (task 11.4).
- **MANUAL-WIDGET-SECRET** — harden the shared bridge secret behind the Android
  keystore instead of SharedPreferences.
- **MANUAL-WIDGET-SIGNER-CROSSCHECK** — assert the Kotlin/Swift signer produces
  the same tag as the Dart signer for shared vectors.
