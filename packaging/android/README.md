# Android release signing (CI)

The Gradle build (`android/app/build.gradle.kts`) signs the release APK/AAB
**only** when `android/key.properties` exists. When it is absent (forks, clean
checkouts) the release build stays unsigned — no source change is required.

The GitHub Actions release workflow (`.github/workflows/github-release.yml`)
reconstructs `android/key.properties` and the keystore from repository secrets
before running `flutter build apk --release`.

## Required GitHub secrets

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Description |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The upload keystore (`*.jks`) base64-encoded. |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore (store) password. |
| `ANDROID_KEY_PASSWORD` | The key password. |
| `ANDROID_KEY_ALIAS` | The key alias (e.g. `forge-upload`). |

If **any** of these are unset, the workflow skips signing and produces an
unsigned release APK — the build still succeeds so forks without secrets are
not blocked.

## Producing `ANDROID_KEYSTORE_BASE64`

Create the upload keystore once (keep it and the passwords safe forever):

```sh
keytool -genkey -v -keystore forge-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias forge-upload
```

Base64-encode it for the secret value:

```sh
# Linux
base64 -w0 forge-upload.jks > forge-upload.jks.b64
# macOS
base64 -i forge-upload.jks -o forge-upload.jks.b64
```

Paste the contents of `forge-upload.jks.b64` into `ANDROID_KEYSTORE_BASE64`.

## How the workflow reconstructs signing

```sh
echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/upload-keystore.jks
cat > android/key.properties <<EOF
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyPassword=$ANDROID_KEY_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
storeFile=upload-keystore.jks
EOF
```

`storeFile` is resolved relative to the `android/` directory by Gradle, so the
decoded keystore is written there. Neither `key.properties` nor the keystore is
committed — both are `.gitignore`d.
