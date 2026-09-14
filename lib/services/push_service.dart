import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
/// Обычные сообщения показывает сама ОС по `notification`-полю FCM
/// (канал/звук по умолчанию). "Позвать" (msg_type='call',
/// ChatSyncService.sendCall) — особый случай: приходит ДАННЫМИ без
/// `notification`-поля и показывается вручную через
/// `flutter_local_notifications` в отдельном канале с рингтоном
/// устройства и усиленной вибрацией — обычный канал звучит слишком
/// буднично для "меня зовут прямо сейчас".
///
/// Пока не пришли реальные значения (`FirebaseSettings.isConfigured`)
/// или платформа не поддерживается — `init()` ничего не делает, вызывать
/// его безопасно всегда.
class PushService {
  final ChatAuthService auth;
  const PushService(this.auth);

  static const String callChannelId = 'coach_call';

  /// ponytail: один слот на "текущий вызов" — если позвонят двое подряд,
  /// второе уведомление заменит первое, а не встанет в очередь. Для
  /// сценария "позвать тренера" этого достаточно; отдельный id на
  /// звонящего добавить несложно, если понадобится.
  static const int _callNotificationId = 9001;

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
      await _initLocalNotifications();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
      messaging.onTokenRefresh.listen(_saveToken);
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    } catch (_) {
      // Push — необязательное усиление доставки (опрос раз в 10-20с и
      // так работает) — сбой здесь не должен ронять чат.
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (message.data['type'] == 'call') showCallNotification(message.data);
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

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

/// Готовит плагин и заводит канал "Позвать" — рингтон устройства
/// (обычно длиннее и громче стандартного уведомления, ровно то, что
/// нужно для ощущения "звонка") плюс усиленная вибрация. Канал
/// создаётся один раз: повторный вызов с тем же id ничего не меняет —
/// Android игнорирует настройки канала при пере-создании, поэтому
/// звук/вибрацию нельзя поменять без удаления канала пользователем
/// вручную (нормальное поведение системы, не баг).
Future<void> _initLocalNotifications() async {
  await _localNotifications.initialize(
    const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: _onNotificationAction,
  );
  final channel = AndroidNotificationChannel(
    PushService.callChannelId,
    'Позвать',
    description: 'Вызов от собеседника в чате — длиннее и громче обычного уведомления',
    importance: Importance.max,
    playSound: true,
    sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
    enableVibration: true,
    vibrationPattern: _callVibrationPattern,
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

/// Три ощутимых импульса вместо одного короткого — заметнее обычного
/// уведомления, но не бесконечно (решение пользователя: без зацикливания
/// "как настоящий звонок", просто громче и дольше).
final Int64List _callVibrationPattern = Int64List.fromList([0, 800, 400, 800, 400, 800]);

void _onNotificationAction(NotificationResponse response) {
  if (response.actionId == 'decline') _localNotifications.cancel(PushService._callNotificationId);
}

/// Показывает уведомление "Позвать" вручную — вызывается и из
/// foreground-обработчика (`PushService._handleForegroundMessage`), и
/// из фонового (`firebaseMessagingBackgroundHandler`), поскольку это
/// две разные точки входа (фон работает в отдельном изоляте, ничего не
/// зная о состоянии приложения).
Future<void> showCallNotification(Map<String, dynamic> data) async {
  await _localNotifications.show(
    PushService._callNotificationId,
    '${data['title'] ?? 'Звонок'}',
    '${data['body'] ?? 'Вас вызывают'}',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.callChannelId,
        'Позвать',
        channelDescription: 'Вызов от собеседника в чате',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        actions: [AndroidNotificationAction('decline', 'Сбросить', cancelNotification: true)],
      ),
    ),
  );
}

/// Обработчик push, пока приложение полностью закрыто/в фоне.
///
/// Обычные сообщения Android показывает сам по `notification`-полю —
/// это тело нужно только чтобы Firebase не жаловался на отсутствие
/// зарегистрированного обработчика. "Позвать" приходит без
/// `notification`-поля (см. Edge Function) именно чтобы ОС не показала
/// его сама в канале по умолчанию — здесь оно показывается вручную, в
/// нужном канале с нужным звуком.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!FirebaseSettings.isConfigured) return;
  await Firebase.initializeApp(options: PushService._options);
  if (message.data['type'] == 'call') {
    await _initLocalNotifications();
    await showCallNotification(message.data);
  }
}
