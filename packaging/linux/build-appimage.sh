#!/usr/bin/env bash
# Build a portable Linux AppImage for Forge from an existing release bundle.
#
# Input : build/linux/x64/release/bundle/  (produced by `flutter build linux --release`)
# Output: Forge-<version>-x86_64.AppImage   (also symlinked as Forge-x86_64.AppImage)
#
# The script is idempotent: it rebuilds the AppDir from scratch on every run and
# reuses a cached appimagetool. GTK3 and libsecret are expected on the host (see
# packaging/linux/README.md); the AppImage bundles the Flutter engine, the app,
# its data/ assets, and any bundled plugin .so files under lib/.
set -euo pipefail

# --- Resolve paths ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="build/linux/x64/release/bundle"
APP_NAME="forge"                 # Linux BINARY_NAME (linux/CMakeLists.txt)
APP_ID="app.forge.forge"         # APPLICATION_ID (linux/CMakeLists.txt)
ICON_SRC="assets/packaging/forge.png"
CACHE_DIR="${FORGE_APPIMAGE_CACHE:-$REPO_ROOT/.appimage-cache}"
APPDIR="$REPO_ROOT/build/linux/Forge.AppDir"

# --- Derive the version from pubspec (e.g. 0.1.0+1 -> 0.1.0) ---------------
RAW_VERSION="$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//')"
APP_VERSION="${RAW_VERSION%%+*}"
[ -n "$APP_VERSION" ] || APP_VERSION="0.0.0"
OUTPUT="Forge-${APP_VERSION}-x86_64.AppImage"

echo "==> Forge AppImage build"
echo "    version : $APP_VERSION"
echo "    bundle  : $BUNDLE_DIR"
echo "    output  : $OUTPUT"

# --- Preconditions ---------------------------------------------------------
if [ ! -d "$BUNDLE_DIR" ]; then
  echo "ERROR: $BUNDLE_DIR not found. Run first:" >&2
  echo "  flutter build linux --release --dart-define=FORGE_SUPABASE_URL=... --dart-define=FORGE_SUPABASE_ANON_KEY=..." >&2
  exit 1
fi
if [ ! -x "$BUNDLE_DIR/$APP_NAME" ]; then
  echo "ERROR: executable $BUNDLE_DIR/$APP_NAME missing or not executable." >&2
  exit 1
fi

# --- Assemble the AppDir from scratch --------------------------------------
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# Copy the whole release bundle (executable + data/ + lib/ + engine .so).
cp -a "$BUNDLE_DIR/." "$APPDIR/usr/bin/"

# Icon: place at both AppDir root and the hicolor theme path.
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
  cp "$ICON_SRC" "$APPDIR/${APP_NAME}.png"
else
  echo "WARN: $ICON_SRC not found; generating a placeholder icon" >&2
  # 1x1 transparent PNG fallback so appimagetool still finds an icon.
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$APPDIR/${APP_NAME}.png"
  cp "$APPDIR/${APP_NAME}.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
fi

# Desktop entry (required by appimagetool; also used by desktop integration).
DESKTOP_FILE="$APPDIR/usr/share/applications/${APP_ID}.desktop"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Forge
GenericName=Personal Productivity
Comment=Forge — Build Better Every Day.
Exec=${APP_NAME}
Icon=${APP_NAME}
Categories=Utility;Office;
Terminal=false
StartupNotify=true
EOF
# appimagetool expects a .desktop at the AppDir root too.
cp "$DESKTOP_FILE" "$APPDIR/${APP_ID}.desktop"

# AppRun: launch the bundled executable with library paths resolved locally.
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
# AppRun entrypoint for the Forge AppImage.
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="$HERE/usr/bin:$PATH"
# Prefer bundled libraries (Flutter engine + bundled plugin .so files) but fall
# back to the host for GTK3/libsecret and their dependencies.
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/forge" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# --- Fetch appimagetool (cached) -------------------------------------------
mkdir -p "$CACHE_DIR"
TOOL="$CACHE_DIR/appimagetool-x86_64.AppImage"
if [ ! -x "$TOOL" ]; then
  echo "==> Downloading appimagetool"
  TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$TOOL_URL" -o "$TOOL"
  else
    wget -q "$TOOL_URL" -O "$TOOL"
  fi
  chmod +x "$TOOL"
fi

# --- Run appimagetool ------------------------------------------------------
# appimagetool itself is an AppImage; on hosts without FUSE, run its extracted
# form. ARCH must be exported for the tool to name the output correctly.
export ARCH="x86_64"
rm -f "$OUTPUT"

run_appimagetool() {
  "$TOOL" "$@"
}

if ! run_appimagetool "$APPDIR" "$OUTPUT" 2>/tmp/forge-appimagetool.log; then
  if grep -qiE 'fuse|dlopen' /tmp/forge-appimagetool.log; then
    echo "==> FUSE unavailable; extracting appimagetool and retrying"
    EXTRACT_DIR="$CACHE_DIR/appimagetool.extracted"
    rm -rf "$EXTRACT_DIR"
    ( cd "$CACHE_DIR" && "$TOOL" --appimage-extract >/dev/null && mv squashfs-root "$EXTRACT_DIR" )
    "$EXTRACT_DIR/AppRun" "$APPDIR" "$OUTPUT"
  else
    echo "ERROR: appimagetool failed:" >&2
    cat /tmp/forge-appimagetool.log >&2
    exit 1
  fi
fi

chmod +x "$OUTPUT"
# Convenience unversioned alias for CI/download links.
ln -sf "$OUTPUT" "Forge-x86_64.AppImage"

echo "==> Built $OUTPUT"
ls -la "$OUTPUT"
file "$OUTPUT"
