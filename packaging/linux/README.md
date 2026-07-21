# Linux AppImage

`build-appimage.sh` turns a Flutter Linux release bundle into a portable
`Forge-<version>-x86_64.AppImage`.

## What it does

- Reads `build/linux/x64/release/bundle/` (the `flutter build linux --release`
  output: the `forge` executable, `data/`, `lib/`, and the Flutter engine `.so`).
- Assembles an `AppDir` with:
  - `AppRun` that launches the bundled `forge` binary with a local
    `LD_LIBRARY_PATH`,
  - a freedesktop `app.forge.forge.desktop` entry,
  - a `forge.png` icon (reused from `assets/packaging/forge.png`).
- Downloads `appimagetool` (x86_64) into `.appimage-cache/` if not already
  present, then produces `Forge-<version>-x86_64.AppImage` plus an unversioned
  `Forge-x86_64.AppImage` symlink.

The script is **idempotent** — it rebuilds the AppDir from scratch each run and
reuses the cached tool.

## Usage

```sh
flutter build linux --release \
  --dart-define=FORGE_SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=FORGE_SUPABASE_ANON_KEY=<public-anon-key>
bash packaging/linux/build-appimage.sh
```

## Host dependencies

The AppImage bundles the Flutter engine and the app, but **GTK3** and
**libsecret** (used by `flutter_secure_storage`) are expected to be present on
the target host — this is standard for Flutter Linux AppImages. On Debian/Ubuntu:

```sh
sudo apt-get install libgtk-3-0 libsecret-1-0
```

## FUSE note

`appimagetool` and the produced AppImage are themselves AppImages and normally
require FUSE to run. The build script automatically falls back to
`--appimage-extract` when FUSE is unavailable, so it works in containers/CI.
To run the produced AppImage without FUSE:

```sh
./Forge-x86_64.AppImage --appimage-extract
./squashfs-root/AppRun
```
