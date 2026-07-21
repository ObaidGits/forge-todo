# Forge

Forge (*Build Better Every Day*) is a local-first personal productivity app.
The implementation targets Android, iOS (build-only until V1), Windows, and
validated Linux combinations. Web and macOS are intentionally not scaffolded.

## For developers

- [DEVELOPMENT.md](DEVELOPMENT.md) — set up the toolchain, run, and test.
- [ARCHITECTURE.md](ARCHITECTURE.md) — how Forge is structured.
- [docs/RELEASE.md](docs/RELEASE.md) — tagging and publishing GitHub Releases.

## Toolchain

Use Flutter 3.44.6 (revision `ee80f08bbf`) with bundled Dart 3.12.2. Copy a
file from `config/*.example.json` outside the example path, keep it ignored,
and pass it through `--dart-define-from-file`. Configuration files must never
contain authorization, signing, database, or service-role secrets.

```sh
FLUTTER_BIN=/path/to/flutter/bin/flutter tool/generate.sh
FLUTTER_BIN=/path/to/flutter/bin/flutter tool/quality.sh
bash tool/ci/pr.sh
FORGE_CONFIG_FILE=config/release.json \
  FLUTTER_BIN=/path/to/flutter/bin/flutter tool/release/build.sh linux
```

Release targets are `android-apk`, `android-appbundle`, `ios`, `windows`, and
`linux`. Release outputs are unsigned until later artifact gates supply and
verify platform identities. Source is MIT licensed; see `LICENSE`,
`THIRD_PARTY_NOTICES.md`, and `assets/licenses/NOTICE.txt`.

## Download & Install

Grab the latest build for your platform from the
[**Releases**](https://github.com/forge-productivity/forge/releases) page.

### Android (APK)

1. Download `Forge-<version>.apk` to your phone.
2. Open it. Android will ask to allow installs from this source — tap
   **Settings → Allow from this source** (unknown-sources), then go back and
   install.
3. Open Forge from your app drawer.

### Windows (installer)

1. Download `Forge-<version>-windows-setup.exe` and run it.
2. Windows SmartScreen may warn about an unrecognized app. Click **More info →
   Run anyway**.
3. The installer runs per-user (no admin needed), installs the Visual C++
   runtime if required, and adds Start-menu (and optional desktop) shortcuts.

### Linux (AppImage)

1. Download `Forge-<version>-x86_64.AppImage`.
2. Make it executable and run it:

   ```sh
   chmod +x Forge-*-x86_64.AppImage
   ./Forge-*-x86_64.AppImage
   ```

   GTK3 and libsecret are expected on the host
   (`sudo apt-get install libgtk-3-0 libsecret-1-0` on Debian/Ubuntu).

### Sync (optional)

Forge is local-first and works fully offline. **Sign in with Google to sync**
your data across devices from the in-app *Account & sync* screen. Sync is only
available in builds configured with a Supabase backend; the default download
keeps everything on your device.
