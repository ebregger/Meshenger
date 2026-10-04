import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.bregger.edison.meshenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Permanent Android identity; keep this unchanged for upgrade compatibility.
        applicationId = "com.bregger.edison.meshenger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
            }
        }
    }

    buildTypes {
        debug {
            // Isolate performance runs from the user's installed app and data.
            if (providers.gradleProperty("meshengerBenchmark").orNull == "true") {
                applicationIdSuffix = ".benchmark"
            }
        }
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Local debug installs still run. Release packaging fails below
                // until tools/create_release_keystore.ps1 has created the keystore.
                signingConfigs.getByName("debug")
            }
        }
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
        // Flutter generates Windows SDK paths in local.properties. This file
        // is local build configuration and is never packaged in the APK.
        disable += "PropertyEscape"
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")
}

gradle.taskGraph.whenReady {
    val packagingRelease = allTasks.any { task ->
        val name = task.name
        task.project.path == ":app" &&
            name.matches(Regex("(assemble|bundle|package|sign).*Release(?:Bundle)?"))
    }
    if (packagingRelease && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "Release builds need android/key.properties. Run tools/create_release_keystore.ps1.",
        )
    }
}

flutter {
    source = "../.."
}
