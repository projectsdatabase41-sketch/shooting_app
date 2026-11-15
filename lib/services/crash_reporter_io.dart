import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_settings.dart';

/// Перехват падений, которые не видит Dart (Android/iOS/macOS).
///
/// `FlutterError.onError` и `PlatformDispatcher.instance.onError` ловят только
/// исключения Dart: если процесс падает в нативной части (плагин, WebView,
/// нехватка памяти), приложение просто исчезает, и в отзывах остаётся
/// «Прошлый сеанс оборвался без выхода» без стека (14–15.11). Crashlytics
/// входит в бесплатный тариф Firebase, проект Firebase у приложения уже есть
/// (им пользуется push), поэтому здесь те же `FirebaseOptions`.
///
/// SDK включается молча: если Firebase недоступен, приложение продолжает
/// работать как раньше, просто без отчётов о падениях.
class CrashReporter {
  static bool _enabled = false;

  /// Включён ли сбор (для диагностики).
  static bool get enabled => _enabled;

  static Future<void> init() async {
    if (kIsWeb || !FirebaseSettings.isConfigured) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: _options);
      }
      final crashlytics = FirebaseCrashlytics.instance;
      await crashlytics.setCrashlyticsCollectionEnabled(true);

      // Прежние обработчики продолжают работать: они отправляют ошибки в
      // отзывы (DemoMode), Crashlytics добавляет к ним нативные падения.
      final prevFlutter = FlutterError.onError;
      FlutterError.onError = (details) {
        prevFlutter?.call(details);
        crashlytics.recordFlutterFatalError(details);
      };
      final prevPlatform = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        prevPlatform?.call(error, stack);
        crashlytics.recordError(error, stack, fatal: true);
        return true;
      };
      _enabled = true;
    } catch (_) {
      // Без Crashlytics приложение обязано запускаться.
    }
  }

  /// Отметка о шаге перед возможным падением: попадёт в отчёт Crashlytics
  /// вместе со стеком (видно, чем занимались в момент вылета).
  static void breadcrumb(String step) {
    if (!_enabled) return;
    try {
      FirebaseCrashlytics.instance.log(step);
    } catch (_) {}
  }

  static FirebaseOptions get _options {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    return FirebaseOptions(
      apiKey: isIOS ? FirebaseSettings.iosApiKey : FirebaseSettings.androidApiKey,
      appId: isIOS ? FirebaseSettings.iosAppId : FirebaseSettings.androidAppId,
      messagingSenderId: FirebaseSettings.messagingSenderId,
      projectId: FirebaseSettings.projectId,
      iosBundleId: isIOS ? 'ru.bsshooting.shootingApp' : null,
    );
  }
}
