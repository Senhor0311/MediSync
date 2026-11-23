plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Owner supplies these values through the process environment. Never print them
// or fall back to debug keys when a production release is requested.
val releaseSigning = listOf("MEDISYNC_KEYSTORE", "MEDISYNC_KEYSTORE_PASSWORD", "MEDISYNC_KEY_ALIAS", "MEDISYNC_KEY_PASSWORD")
val signingAvailable = releaseSigning.all { !System.getenv(it).isNullOrBlank() }
val releaseRequested = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
if (releaseRequested && !signingAvailable) {
    throw GradleException("Production release signing is required. Supply MEDISYNC_KEYSTORE, MEDISYNC_KEYSTORE_PASSWORD, MEDISYNC_KEY_ALIAS and MEDISYNC_KEY_PASSWORD. Debug/emulator packaging remains available.")
}

android {
    namespace = "com.leandroamaro.medisync_v3"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.leandroamaro.medisync_v3"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingAvailable) create("ownerRelease") {
            storeFile = file(System.getenv("MEDISYNC_KEYSTORE"))
            storePassword = System.getenv("MEDISYNC_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("MEDISYNC_KEY_ALIAS")
            keyPassword = System.getenv("MEDISYNC_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            signingConfig = if (signingAvailable) signingConfigs.getByName("ownerRelease") else null
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
