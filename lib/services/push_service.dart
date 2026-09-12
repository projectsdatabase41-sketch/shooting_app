import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'chat_settings.dart';
import 'firebase_settings.dart';

/// Push-уведомления чата через Firebase (FCM) — ДОБАВКА к Supabase, не
/// замена: сообщения/контакты/вход остаются там же, Firebase здесь
/// только доставляет сигнал "новое сообщение" в закрытое приложение
/// (реальную отправку делает Edge Function на стороне Supabase, см.
/// supabase/functions/send-chat-push/index.ts).
///
/// Пока не пришли реальные значения (`FirebaseSettings.isConfigured`)
/// или платформа не поддерживается — `init()` ничего не делает, вызывать
/// его безопасно всегда.
class PushService {
  final ChatAuthService auth;
  const PushService(this.auth);

  /// Android и iOS — `firebase_messaging` поддерживает оба (iOS через
  /// APNs). Windows desktop у пакета вообще нет реализации (тот же
  /// пробел, что у `camera`/`image_picker`), а веб-push требует
  /// отдельную настройку (service worker, VAPID-ключ) — не делаем в
  /// этом заходе, чтобы не разрастаться.
  ///
  /// iOS-таргет в проекте есть (`ios/`), но собрать и проверить его
  /// можно только на Mac с Xcode — здесь этого сделать нельзя. Когда
  /// дойдёт до реальной сборки, там же в Xcode нужно включить Push
  /// Notifications и Background Modes → Remote notifications
  /// capability, иначе `requestPermission`/`getToken` не сработают.
  static bool get _supportedPlatform =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!FirebaseSettings.isConfigured || !_supportedPlatform || !auth.isSignedIn) return;
    try {
      await Firebase.initializeApp(options: _options);
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
      messaging.onTokenRefresh.listen(_saveToken);
    } catch (_) {
      // Push — необязательное усиление доставки (опрос раз в 10-20с и
      // так работает) — сбой здесь не должен ронять чат.
    }
  }

  static FirebaseOptions get _options {
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return FirebaseOptions(
      apiKey: isIOS ? FirebaseSettings.iosApiKey : FirebaseSettings.androidApiKey,
      appId: isIOS ? FirebaseSettings.iosAppId : FirebaseSettings.androidAppId,
      messagingSenderId: FirebaseSettings.messagingSenderId,
      projectId: FirebaseSettings.projectId,
      iosBundleId: isIOS ? 'ru.bsshooting.shootingApp' : null,
    );
  }

  Future<void> _saveToken(String token) async {
    final freshToken = await auth.ensureFreshToken();
    if (freshToken == null) return;
    final client = http.Client();
    try {
      await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_push_tokens'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $freshToken',
              'Content-Type': 'application/json',
              // Тот же токен устройства при повторной регистрации не
              // создаёт вторую строку.
              'Prefer': 'return=minimal,resolution=merge-duplicates',
            },
            body: jsonEncode({'user_id': auth.userId, 'token': token}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Не смогли сохранить токен сейчас — просто не будет push до
      // следующего успешного запуска, опрос всё равно работает.
    } finally {
      client.close();
    }
  }
}

/// Обработчик push, пока приложение полностью закрыто/в фоне — Android
/// сам показывает уведомление по notification-полю сообщения (см.
/// Edge Function), это тело нужно только чтобы Firebase не жаловался
/// на отсутствие зарегистрированного обработчика. Раскрывать сообщение
/// внутри приложения, пока оно открыто (foreground), не делаем в этом
/// заходе — опрос раз в 10-20с и так покажет новое сообщение почти сразу,
/// а показ уведомления поверх открытого экрана потребовал бы отдельного
/// пакета (flutter_local_notifications) ради не самого частого случая.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!FirebaseSettings.isConfigured) return;
  await Firebase.initializeApp(options: PushService._options);
}
