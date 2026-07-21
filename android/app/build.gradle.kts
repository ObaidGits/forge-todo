import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by an untracked `android/key.properties` (kept out
// of git; see android/.gitignore). When that file is ABSENT — CI, contributors,
// and anyone without the signing key — the release build stays UNSIGNED, exactly
// as before, so protected release automation and clean checkouts are unaffected.
// When it is PRESENT, the release build is signed with the referenced keystore,
// so `flutter build appbundle --release` produces an upload-ready artifact.
// See android/key.properties.example for the required keys.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.forge.forge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (uses java.time APIs on
        // minSdk 24). Desugaring backports them so the debug/release APK links.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.forge.forge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Wave 0 validated Android API 24 as the minimum target.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only materialize the release signing config when key.properties is
        // present; its values come from that untracked file, never from source.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Signed with the upload keystore when key.properties exists;
            // otherwise intentionally unsigned (debug keys must never sign
            // releases — protected automation supplies publisher identity).
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backports java.time (and related APIs) used by flutter_local_notifications
    // on minSdk 24. Required because `isCoreLibraryDesugaringEnabled = true` is
    // set above; without a declared desugaring dependency the l8 dexer fails.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
