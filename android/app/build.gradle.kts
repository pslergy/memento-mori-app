import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Локально: android/key.properties + my-key.jks в android/ (см. docs/ANDROID_RELEASE_SIGNING_RU.md)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreConfigured = keystorePropertiesFile.exists()
if (keystoreConfigured) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.memento_mori_app"
    compileSdk = 34
    // jni / sound_generator plugins expect different NDK; pin highest (backward compatible).
    ndkVersion = "28.2.13676358"

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
    }

    defaultConfig {
        applicationId = "com.example.memento_mori_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        multiDexEnabled = true
    }

    compileOptions {
        // ✅ ВКЛЮЧАЕМ DESUGARING ПРАВИЛЬНО
        isCoreLibraryDesugaringEnabled = true

        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        if (keystoreConfigured) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")!!
                keyPassword = keystoreProperties.getProperty("keyPassword")!!
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile")!!)
                storePassword = keystoreProperties.getProperty("storePassword")!!
            }
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName(
                if (keystoreConfigured) "release" else "debug",
            )

            // R8: обфускация + удаление неиспользуемого Java/Kotlin (Dart AOT отдельно)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ✅ ИСПРАВЛЕННЫЙ СИНТАКСИС (Добавлены скобки и кавычки)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Align with root resolutionStrategy — avoids NoSuchMethodError in Flutter TextInputPlugin (stylus / EditorInfoCompat).
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("com.google.android.gms:play-services-base:18.3.0")
    implementation("androidx.multidex:multidex:2.0.1")
}
