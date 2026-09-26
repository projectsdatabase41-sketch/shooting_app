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

    // Постоянный ключ подписи из секретов GitHub (ANDROID_KEYSTORE_*, см.
    // build-apk.yml). Без него каждая сборка на CI подписывалась новым
    // случайным debug-ключом, и APK не ставился поверх прежнего
    // («конфликтует с другим пакетом»). Локально ключа нет — debug, как раньше.
    val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "pusl"
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
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
