# Development

This guide covers setting up a local development environment for Forge and the
day-to-day loop: fetch dependencies, run, test, analyze. Forge is a local-first
Flutter app with an encrypted on-device database; cloud sync is optional.

## Prerequisites

### Toolchain (pinned)

- **Flutter 3.44.6** (revision `ee80f08bbf`) with bundled **Dart 3.12.2**.
  These are pinned in `pubspec.yaml` (`environment:`) and `.flutter-version`;
  CI enforces them. Use exactly these versions — newer/older SDKs are not
  supported.

Verify:

```sh
flutter --version   # expect 3.44.6 / Dart 3.12.2
cat .flutter-version # expect 3.44.6
```

### Linux desktop build dependencies

The Linux target and some plugins need system dev packages. On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev \
  libsecret-1-dev \
  libkeybinder-3.0-dev
```

Why these matter:

- `ninja-build`, `cmake`, `clang`, `pkg-config`, `libgtk-3-dev` — the standard
  Flutter Linux desktop toolchain.
- `libsecret-1-dev` — backs `flutter_secure_storage` (the device key custodian).
- `libkeybinder-3.0-dev` — required at build time by the desktop global-hotkey
  plugin (`hotkey_manager`) used by the sticky-widget summon shortcut.

### Android build dependencies

- **JDK 17** (Temurin recommended). The Android Gradle build targets Java 17.
- **Android SDK** with `compileSdk` / `targetSdk` supplied by Flutter (SDK 36
  for this Flutter pin); **minSdk 24** (validated minimum).
- Core-library desugaring is enabled (needed by `flutter_local_notifications`).

## Get dependencies

```sh
flutter pub get
```

CI uses `flutter pub get --enforce-lockfile`; keep `pubspec.lock` committed and
in sync. Some code is generated (Drift, localizations). Regenerate when schema
or l10n change:

```sh
dart run build_runner build --delete-conflicting-outputs
```

`tool/generate.sh` wraps generation for the repo's conventions.

## Run the app

### Linux desktop

```sh
flutter run -d linux
```

### Android (emulator or device)

Boot an emulator (or attach a device), then:

```sh
flutter devices          # confirm the target is listed
flutter run -d <deviceId>
```

### Encrypted database / sqlite3mc note

Forge's source of truth is an **encrypted SQLite database**. The `sqlite3`
package is configured (via the `hooks.user_defines` block in `pubspec.yaml`) to
build the **SQLite3 Multiple Ciphers (sqlite3mc)** native asset, so the store
opens with a `PRAGMA key` (ADR-0001). The 32-byte database key is custodied by
the device key vault (OS secret service via `libsecret`/Keychain/DPAPI/Keystore,
with a local file-vault fallback). No extra setup is needed for a normal run —
the native asset is compiled by the build — but a first run provisions a fresh
key only on a provably clean install; existing ciphertext without a key fails
closed into Recovery Mode by design.

## Test

```sh
flutter test --no-pub test/
```

> **Important:** run `flutter test` **without an emulator or device booted**.
> Forge's suite includes property-based tests; running them while a device is
> attached competes for resources and can cause those tests to time out. If a
> property test times out under load, re-run it alone (e.g.
> `flutter test test/<path>/<file>_test.dart`) to confirm it is green.

Integration smoke test (`integration_test/app_launch_test.dart`) requires a
device/emulator and is run separately from the unit/widget suite.

## Analyze

```sh
flutter analyze --no-pub
```

Lints are configured in `analysis_options.yaml` (`flutter_lints`). `tool/quality.sh`
runs the repo's full quality gate (format check, analyze, tests).

## Optional Supabase sync (dart-defines)

Forge works fully offline. Cloud sync is enabled **only** when both build-time
dart-defines are present; otherwise the sync service is null and the app is
purely local:

```sh
flutter run -d linux \
  --dart-define=FORGE_SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=FORGE_SUPABASE_ANON_KEY=<public-anon-key>
```

The keys are read by `lib/features/sync/infrastructure/supabase_sync_environment.dart`
(`SyncDartDefines.url` / `SyncDartDefines.anonKey`). You can also pass them via
`--dart-define-from-file` using a copy of `config/*.example.json` kept outside
the example path (config files must never contain secrets). See
[docs/SUPABASE_SETUP.md](docs/SUPABASE_SETUP.md) for cloud setup.

### Local Supabase dev workflow

To iterate on the sync schema/RPCs locally with the Supabase CLI:

```sh
supabase start            # boot local stack (Studio on :54323, API on :54321)
supabase db reset         # apply migrations in supabase/migrations + seed.sql
```

The local API exposes the `forge` schema (see `supabase/config.toml` →
`[api] schemas`), which holds the protocol-v2 sync RPCs. Database tests live in
`supabase/tests/`. Reset re-applies migrations and reseeds, giving a clean local
backend to point a dev build at (`FORGE_SUPABASE_URL=http://127.0.0.1:54321`).

## More

- [ARCHITECTURE.md](ARCHITECTURE.md) — system overview and layering.
- [docs/SUPABASE_SETUP.md](docs/SUPABASE_SETUP.md) — cloud backend runbook.
- [docs/RELEASE.md](docs/RELEASE.md) — tagging and GitHub Releases.
- [docs/architecture/data-dictionary.md](docs/architecture/data-dictionary.md) —
  the persisted data model.
