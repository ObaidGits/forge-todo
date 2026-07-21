# Release

Forge ships through **GitHub Releases**. Pushing a `v*` tag triggers
`.github/workflows/github-release.yml`, which builds the Android APK, the
Windows installer, and the Linux AppImage, then publishes them all to a Release
for the tag.

## Required GitHub Actions secrets

Add these under **Settings → Secrets and variables → Actions**. All are
optional in the sense that a missing secret degrades gracefully (sync stays off;
Android stays unsigned) — but a real distribution wants all of them.

| Secret | Purpose |
| --- | --- |
| `SUPABASE_URL` | Injected as `--dart-define=FORGE_SUPABASE_URL`. Empty = sync off. |
| `SUPABASE_ANON_KEY` | Injected as `--dart-define=FORGE_SUPABASE_ANON_KEY`. Empty = sync off. |
| `ANDROID_KEYSTORE_BASE64` | Upload keystore (`*.jks`), base64-encoded. |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore (store) password. |
| `ANDROID_KEY_PASSWORD` | Key password. |
| `ANDROID_KEY_ALIAS` | Key alias (e.g. `forge-upload`). |

If **all four** Android secrets are present, CI reconstructs
`android/key.properties` + the keystore and produces a **signed** APK. If any is
missing, the APK is built **unsigned** and the build still succeeds (forks
without secrets are not blocked). Sync keys behave the same way: present =
sync-capable build, absent = local-only build.

## Creating the Android upload keystore

Create it once and keep the file and passwords safe forever (losing it means you
can no longer update a published app unless enrolled in Play App Signing):

```sh
keytool -genkey -v -keystore forge-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias forge-upload
```

Base64-encode it for the `ANDROID_KEYSTORE_BASE64` secret:

```sh
base64 -w0 forge-upload.jks > forge-upload.jks.b64   # Linux
base64 -i forge-upload.jks -o forge-upload.jks.b64   # macOS
```

Paste the contents of `forge-upload.jks.b64` into the secret. See
[packaging/android/README.md](../packaging/android/README.md) for how the
workflow rebuilds signing, and `android/key.properties.example` for local
signing.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (the workflow derives the release name and
   asset names from it).
2. Commit, then push a matching tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. The `github-release` workflow runs three build jobs in parallel:
   - **Linux** → `flutter build linux --release` → `packaging/linux/build-appimage.sh`
     → `Forge-<version>-x86_64.AppImage`
   - **Windows** → `flutter build windows --release` → Inno Setup
     (`packaging/windows/forge.iss`) → `Forge-<version>-windows-setup.exe`
   - **Android** → `flutter build apk --release` → `Forge-<version>.apk`
4. The `release` job downloads all artifacts, renames them, and publishes (or
   updates) the GitHub Release for the tag with auto-generated notes.

You can also trigger the workflow manually via **workflow_dispatch** to build
the artifacts without publishing a Release (publishing only happens on real tag
pushes).

## Packaging references

- Linux AppImage — [packaging/linux/README.md](../packaging/linux/README.md)
- Windows installer (Inno Setup) — [packaging/windows/README.md](../packaging/windows/README.md)
- Android signing — [packaging/android/README.md](../packaging/android/README.md)
