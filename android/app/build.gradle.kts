plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.memento_mori_app"
    compileSdk = 34

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

    buildTypes {
        getByName("release") {
            // Для теста используем debug ключ, но в будущем создай свой
            signingConfig = signingConfigs.getByName("debug")

            // На время Глобального теста оставляем false, чтобы легче дебажить
            isMinifyEnabled = false
            isShrinkResources = false
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
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.gms:play-services-base:18.3.0")
    implementation("androidx.multidex:multidex:2.0.1")
}
