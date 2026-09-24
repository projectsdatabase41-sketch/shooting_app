plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.shooting_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (уведомление "Позвать", см.
        // push_service.dart) использует java.time через desugaring —
        // без этого релизная сборка падает на "requires core library
        // desugaring to be enabled".
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Постоянный идентификатор приложения на устройстве. Менять
        // его позже нельзя без переустановки с потерей базы, поэтому
        // com.example (заглушка из шаблона) заменён сразу.
        applicationId = "ru.bsshooting.shooting_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23) // flutter_webrtc
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Требуется isCoreLibraryDesugaringEnabled выше — версия свежая по
    // рекомендации самой ошибки сборки, независимо от версии Android Gradle Plugin.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
