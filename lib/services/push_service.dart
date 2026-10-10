import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'call_service.dart';
import 'chat_auth_service.dart';
import '../logic/notification_avatar.dart';
import 'chat_settings.dart';
import 'db_opener.dart';
import 'firebase_settings.dart';
import 'web_push_token.dart';
import '../i18n/i18n.dart';

/// Куда открыть чат по тапу на уведомление — общий чат или переписка с
/// конкретным контактом (см. `PushService._handleTap`, обработчик
/// навигации в `main.dart`).
class PushChatTarget {
  final bool isGlobal;
  final String? contactId;
  const PushChatTarget.global()
      : isGlobal = true,
        contactId = null;
  const PushChatTarget.personal(String this.contactId) : isGlobal = false;
}

/// Единственный обработчик на всё приложение — куда бы ни пришёл тап
/// (уведомление FCM или локальное "Позвать"), логика "какой экран
/// открыть" одна и та же, и владеет ей корневой виджет (`main.dart`),
/// у которого есть доступ к `Navigator`.
void Function(PushChatTarget target)? pushChatTapHandler;

/// Звонящий отменил вызов до ответа — погасить экран входящего.
void Function(String callId)? incomingCallEndHandler;

/// Убрать уведомление входящего звонка (приняли/отклонили на экране).
Future<void> cancelIncomingCallNotification() async {
  if (!PushService._isAndroid) return;
  try {
    await _localNotifications.cancel(PushService._incomingCallNotificationId);
  } catch (_) {}
}

/// Входящий звонок: открыть экран звонка ([accepted] — уже нажали «Принять»
/// в уведомлении). Задаёт корень приложения (`main.dart`).
void Function(Map<String, dynamic> data, {required bool accepted})?
    incomingCallHandler;

/// Контакт, чей вызов тренер принял кнопкой «Иду» на уведомлении: после
/// открытия переписки и подгрузки сообщений вызов подтверждается сам
/// (`call_ack`), не требуя второго нажатия внутри чата.
String? pendingCallAckContactId;

bool _tapHandlingRegistered = false;
bool _foregroundRegistered = false;

/// Тап по push задания — открыть это задание (задаёт корень приложения).
void Function(String taskId)? pushTaskTapHandler;

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
  static const String messageChannelId = 'chat_messages';
  static const int _incomingCallNotificationId = 9002;

  /// ponytail: один слот на "текущий вызов" — если позвонят двое подряд,
  /// второе уведомление заменит первое, а не встанет в очередь. Для
  /// сценария "позвать тренера" этого достаточно; отдельный id на
  /// звонящего добавить несложно, если понадобится.
  static const int _callNotificationId = 9001;

  /// Android, iOS и веб. Windows desktop у пакета вообще нет реализации
  /// (тот же пробел, что у `camera`/`image_picker`).
  ///
  /// Веб включает push и на iPhone (Safari 16.4+) — но ТОЛЬКО когда сайт
  /// добавлен на домашний экран как приложение, обычная вкладка такого
  /// разрешения не получает (см. `web/firebase-messaging-sw.js`).
  ///
  /// iOS-таргет в проекте есть (`ios/`), но собрать и проверить его
  /// можно только на Mac с Xcode — здесь этого сделать нельзя. Когда
  /// дойдёт до реальной сборки, там же в Xcode нужно включить Push
  /// Notifications и Background Modes → Remote notifications
  /// capability, иначе `requestPermission`/`getToken` не сработают.
  static bool get _supportedPlatform =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Токен на вебе — через собственный мост (web/push-bridge.js), см. там причину.
  static Future<String?> _webToken() => webPushToken({
        'apiKey': FirebaseSettings.webApiKey,
        'appId': FirebaseSettings.webAppId,
        'messagingSenderId': FirebaseSettings.messagingSenderId,
        'projectId': FirebaseSettings.projectId,
        'authDomain': FirebaseSettings.webAuthDomain,
      }, FirebaseSettings.webVapidKey);

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (!FirebaseSettings.isConfigured ||
        !_supportedPlatform ||
        !auth.isSignedIn) return;
    try {
      // init() вызывается из нескольких мест (корень приложения — ради
      // холодного старта по тапу на уведомление, и ChatHomeScreen — после
      // входа в чат), Firebase инициализируется только один раз.
      if (kIsWeb) {
        // Веб: токен берёт мост на JS (web/push-bridge.js) — Dart-обёртка
        // Firebase на iPhone падает при инициализации (Null check).
        if (await webRequestPermission() != 'granted') return;
        final t = await _webToken();
        if (t != null) await _saveToken(t);
        return;
      }
      if (Firebase.apps.isEmpty)
        await Firebase.initializeApp(options: _options);
      // Канал с рингтоном/вибрацией — только Android (см. showCallNotification).
      if (_isAndroid) await _initLocalNotifications();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
      messaging.onTokenRefresh.listen(_saveToken);
      await _registerListeners(messaging);
    } catch (_) {
      // Push — необязательное усиление доставки (опрос раз в 10-20с и
      // так работает) — сбой здесь не должен ронять чат.
    }
  }

  /// Включение push по нажатию кнопки — жест пользователя обязателен
  /// (iOS Safari молча отклоняет запрос разрешения при автозапуске), и
  /// человек видит причину, а не тишину. Возвращает готовый текст статуса.
  Future<String> enableNow() async {
    if (!FirebaseSettings.isConfigured || !_supportedPlatform) {
      return tr('На этой платформе push не поддерживается');
    }
    if (!auth.isSignedIn) return tr('Сначала войдите в мессенджер');
    String step = 'старт';
    if (kIsWeb) {
      final env = webPushEnv();
      if (env == 'ios-not-installed') {
        return tr(
            'iPhone: push работает только у приложения с домашнего экрана. В Safari нажмите «Поделиться» → «На экран Домой», откройте Nexus с иконки и нажмите эту кнопку снова. Нужен iOS 16.4 или новее.');
      }
      if (env == 'unsupported') {
        return tr(
            'Этот браузер не поддерживает push. На iPhone нужен iOS 16.4+ и Safari; в других браузерах — обновите их.');
      }
    }
    try {
      if (kIsWeb) {
        // Первым делом, без await до этого: iOS требует запрос в жесте нажатия.
        step = 'запрос разрешения';
        final perm = await webRequestPermission();
        if (perm != 'granted') {
          return tr(
              'Разрешение на уведомления не выдано ({p}) — включите его: Настройки iPhone → Уведомления → Nexus', {'p': perm});
        }
      }
      if (kIsWeb) {
        step = 'получение адреса устройства';
        final t = await _webToken();
        if (t == null) return tr('Не удалось получить адрес устройства для push');
        step = 'сохранение на сервере';
        await _saveToken(t);
        return tr('Уведомления включены');
      }
      step = 'инициализация Firebase';
      if (Firebase.apps.isEmpty)
        await Firebase.initializeApp(options: _options);
      if (_isAndroid) await _initLocalNotifications();
      final messaging = FirebaseMessaging.instance;
      step = 'разрешение';
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return tr(
            'Разрешение на уведомления не выдано — включите его в настройках браузера или телефона');
      }
      step = 'получение адреса устройства';
      final token = await messaging.getToken();
      if (token == null)
        return tr('Не удалось получить адрес устройства для push');
      step = 'сохранение на сервере';
      await _saveToken(token);
      await _registerListeners(messaging);
      return tr('Уведомления включены');
    } catch (e) {
      // Кнопка диагностическая: показываем шаг и исходный текст ошибки.
      final raw = e.toString();
      return tr('Ошибка на шаге «{s}»: {e}', {
        's': step,
        'e': raw.length > 220 ? '${raw.substring(0, 220)}…' : raw
      });
    }
  }

  /// Адрес устройства для push ЗАДАНИЙ — без входа в мессенджер (задания
  /// идут своим каналом). null — push недоступен на этой платформе/сборке.
  static Future<String?> deviceToken() async {
    if (!FirebaseSettings.isConfigured || !_supportedPlatform) return null;
    try {
      if (kIsWeb) {
        return await webRequestPermission() == 'granted' ? await _webToken() : null;
      }
      if (Firebase.apps.isEmpty)
        await Firebase.initializeApp(options: _options);
      if (_isAndroid) await _initLocalNotifications();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      await _registerListeners(messaging);
      return await messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  /// Подписки на входящие и тапы — один раз на приложение (их зовут и чат, и задания).
  static Future<void> _registerListeners(FirebaseMessaging messaging) async {
    if (!_foregroundRegistered) {
      _foregroundRegistered = true;
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    }
    await _initTapHandling(messaging);
  }

  static void _handleForegroundMessage(RemoteMessage message) {
    if (message.data['type'] == 'task' && _isAndroid)
      showTaskNotification(message.data);
    if (message.data['type'] == 'coach_call' && _isAndroid)
      showCoachCallNotification(message.data);
    // На вебе/iOS усиленного канала нет (см. showCallNotification) —
    // пока приложение открыто, новое "Позвать" и так почти сразу
    // покажет опрос (10-20с), отдельно тут его не дублируем.
    if (_isAndroid && message.data['type'] == 'call')
      showCallNotification(message.data);
    // Приложение открыто — сразу экран входящего звонка, плюс рингтон
    // уведомлением (иначе звонок был бы беззвучным).
    if (message.data['type'] == 'call_in') {
      if (_isAndroid) showIncomingCallNotification(message.data);
      incomingCallHandler?.call(message.data, accepted: false);
    }
    if (message.data['type'] == 'msg_delete' && _isAndroid) {
      _localNotifications
          .cancel('${message.data['contact_id']}'.hashCode & 0x3fffffff);
    }
    if (message.data['type'] == 'call_end') {
      cancelIncomingCallNotification();
      incomingCallEndHandler?.call('${message.data['call_id']}');
    }
  }

  /// Тап на уведомление должен открыть ИМЕННО тот чат, откуда сообщение,
  /// а не просто запустить приложение на главный экран. `init()` зовут и
  /// из корня приложения, и из ChatHomeScreen — подписка нужна только
  /// один раз, дальше `pushChatTapHandler` вызывается напрямую.
  static Future<void> _initTapHandling(FirebaseMessaging messaging) async {
    if (_tapHandlingRegistered) return;
    _tapHandlingRegistered = true;
    final initial = await messaging.getInitialMessage();
    if (initial != null) _handleTap(initial);
    // Приложение запущено тапом по НАШЕМУ уведомлению (сообщение с фото
    // или «Позвать») — открыть нужный чат.
    if (_isAndroid) {
      final launch =
          await _localNotifications.getNotificationAppLaunchDetails();
      final resp = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && resp != null)
        _onNotificationAction(resp);
    }
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
  }

  static void _handleTap(RemoteMessage message) {
    final type = message.data['type'];
    if (type == 'task') {
      final id = '${message.data['task_id'] ?? ''}';
      if (id.isNotEmpty) pushTaskTapHandler?.call(id);
      return;
    }
    if (type == 'global' || type == 'friend') {
      // Заявка в друзья: открываем мессенджер — красный кружок у меню ведёт к «Друзьям».
      pushChatTapHandler?.call(const PushChatTarget.global());
    } else {
      final contactId = message.data['contact_id'];
      if (contactId is String && contactId.isNotEmpty) {
        pushChatTapHandler?.call(PushChatTarget.personal(contactId));
      }
    }
  }

  static FirebaseOptions get _options {
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    if (kIsWeb) {
      return const FirebaseOptions(
        apiKey: FirebaseSettings.webApiKey,
        appId: FirebaseSettings.webAppId,
        messagingSenderId: FirebaseSettings.messagingSenderId,
        projectId: FirebaseSettings.projectId,
        authDomain: FirebaseSettings.webAuthDomain,
      );
    }
    return FirebaseOptions(
      apiKey:
          isIOS ? FirebaseSettings.iosApiKey : FirebaseSettings.androidApiKey,
      appId: isIOS ? FirebaseSettings.iosAppId : FirebaseSettings.androidAppId,
      messagingSenderId: FirebaseSettings.messagingSenderId,
      projectId: FirebaseSettings.projectId,
      iosBundleId: isIOS ? 'ru.bsshooting.shootingApp' : null,
    );
  }

  Future<void> _saveToken(String token) async {
    final freshToken = await auth.ensureFreshToken();
    if (freshToken == null) return;
    // Тот же токен — серверу звонков (Cloudflare), чтобы дозвониться до закрытого приложения.
    CallService(auth).registerDevice(token).catchError((_) {});
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

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

/// Готовит плагин и заводит канал "Позвать" — рингтон устройства
/// (обычно длиннее и громче стандартного уведомления, ровно то, что
/// нужно для ощущения "звонка") плюс усиленная вибрация. Канал
/// создаётся один раз: повторный вызов с тем же id ничего не меняет —
/// Android игнорирует настройки канала при пере-создании, поэтому
/// звук/вибрацию нельзя поменять без удаления канала пользователем
/// вручную (нормальное поведение системы, не баг).
Future<void> _initLocalNotifications() async {
  await _localNotifications.initialize(
    const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: _onNotificationAction,
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(AndroidNotificationChannel(
        PushService.messageChannelId,
        tr('Сообщения'),
        description: tr('Новые сообщения в личных чатах'),
        importance: Importance.high,
      ));
  final channel = AndroidNotificationChannel(
    PushService.callChannelId,
    tr('Позвать'),
    description: tr(
        'Вызов от собеседника в чате — длиннее и громче обычного уведомления'),
    importance: Importance.max,
    playSound: true,
    sound:
        const UriAndroidNotificationSound('content://settings/system/ringtone'),
    enableVibration: true,
    vibrationPattern: _callVibrationPattern,
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

/// Три ощутимых импульса вместо одного короткого — заметнее обычного
/// уведомления, но не бесконечно (решение пользователя: без зацикливания
/// "как настоящий звонок", просто громче и дольше).
final Int64List _callVibrationPattern =
    Int64List.fromList([0, 800, 400, 800, 400, 800]);

void _onNotificationAction(NotificationResponse response) {
  if (response.actionId == 'decline') {
    _localNotifications.cancel(PushService._callNotificationId);
    return;
  }
  // Входящий звонок: payload — JSON с данными звонка.
  final payload = response.payload ?? '';
  if (payload.startsWith('task:')) {
    pushTaskTapHandler?.call(payload.substring(5));
    return;
  }
  if (payload.startsWith('{')) {
    _localNotifications.cancel(PushService._incomingCallNotificationId);
    if (response.actionId == 'call_decline')
      return; // звонящий увидит «не отвечает»
    try {
      final data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      incomingCallHandler?.call(data,
          accepted: response.actionId == 'call_accept');
    } catch (_) {}
    return;
  }
  // Тап по телу уведомления ИЛИ кнопка "Иду" (не "Сбросить") — открыть
  // чат со звонящим, тот же payload-приём, что и у FCM-уведомлений
  // обычных сообщений (см. PushService._handleTap), но здесь контакт
  // передан через payload, а не через data сообщения — это ЛОКАЛЬНОЕ
  // уведомление, Android/iOS ничего не знают о FCM data при его тапе.
  final contactId = response.payload;
  if (contactId != null && contactId.isNotEmpty) {
    if (response.actionId == 'open') pendingCallAckContactId = contactId;
    pushChatTapHandler?.call(PushChatTarget.personal(contactId));
  }
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
    NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.callChannelId,
        tr('Позвать'),
        channelDescription: tr('Вызов от собеседника в чате'),
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        // FLAG_INSISTENT (4): рингтон повторяется, пока тренер не нажмёт
        // «Иду»/«Сбросить» или не смахнёт уведомление — чтобы вызов
        // услышали, а не пропустили одним коротким сигналом.
        additionalFlags: Int32List.fromList([4]),
        timeoutAfter: 120000,
        // «Иду» — отдельная явная кнопка вместо единственного тапа по
        // телу уведомления: откликнуться на вызов тренеру стало на один
        // жест заметнее (решение пользователя, пункт 22 списка правок).
        // Открывает переписку тем же путём, что и обычный тап — там уже
        // есть кнопка "Иду" на самом сообщении, отправляющая сигнал
        // `call_ack` (см. `ChatSyncService.acknowledgeCall`).
        actions: [
          AndroidNotificationAction('open', tr('Иду'),
              showsUserInterface: true, cancelNotification: true),
          AndroidNotificationAction('decline', tr('Сбросить'),
              cancelNotification: true),
        ],
      ),
    ),
    payload: data['contact_id'] as String?,
  );
}

/// Обычное сообщение (Android): приходит ДАННЫМИ (`type: 'msg'`, см.
/// send-chat-push), чтобы вместо значка приложения показать фото
/// отправителя с маленьким значком приложения в углу. Фото берём из
/// локальных контактов — в push оно не влезает (лимит 4 КБ).
Future<void> showMessageNotification(Map<String, dynamic> data) async {
  final contactId = '${data['contact_id'] ?? ''}';
  if (await _isMuted(contactId)) return;
  Uint8List? icon;
  try {
    final badge =
        (await rootBundle.load('assets/icon/badge.png')).buffer.asUint8List();
    icon = composeNotificationAvatar(await _contactAvatar(contactId), badge);
  } catch (_) {}
  await _localNotifications.show(
    contactId.hashCode &
        0x3fffffff, // одно уведомление на собеседника, новые его обновляют
    '${data['title'] ?? 'Сообщение'}',
    '${data['body'] ?? ''}',
    NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.messageChannelId,
        tr('Сообщения'),
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        largeIcon: icon == null ? null : ByteArrayAndroidBitmap(icon),
      ),
    ),
    payload: contactId,
  );
}

/// Диалог с выключенным колокольчиком (ChatPreferences.mutedFor).
Future<bool> _isMuted(String contactId) async {
  if (contactId.isEmpty) return false;
  try {
    final db = await openAppDatabase();
    try {
      final rows =
          db.select('SELECT chat_muted_ids FROM project_settings WHERE id = 1');
      return rows.isNotEmpty &&
          '${rows.first['chat_muted_ids'] ?? ''}'
              .split(',')
              .contains(contactId);
    } finally {
      db.close();
    }
  } catch (_) {
    return false; // колонки ещё нет (приложение не открывали после обновления)
  }
}

/// Фото собеседника из локальной базы — отдельным коротким подключением
/// только на чтение: фоновый изолят не должен запускать миграции.
Future<String?> _contactAvatar(String contactId) async {
  if (contactId.isEmpty) return null;
  final db = await openAppDatabase();
  try {
    final rows = db.select(
        'SELECT avatar_base64 FROM chat_contacts WHERE id = ?', [contactId]);
    return rows.isEmpty ? null : rows.first['avatar_base64'] as String?;
  } finally {
    db.close();
  }
}

/// Входящий звонок, когда приложение свёрнуто или закрыто: уведомление на
/// весь экран (как у обычной звонилки) с кнопками «Принять»/«Отклонить».
Future<void> showIncomingCallNotification(Map<String, dynamic> data) async {
  final video = data['video'] == '1';
  await _localNotifications.show(
    PushService._incomingCallNotificationId,
    '${data['name'] ?? 'Звонок'}',
    video ? tr('Входящий видеозвонок') : tr('Входящий звонок'),
    NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.callChannelId,
        tr('Позвать'),
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        timeoutAfter: 45000,
        actions: [
          AndroidNotificationAction('call_decline', tr('Отклонить'),
              cancelNotification: true),
          AndroidNotificationAction('call_accept', tr('Принять'),
              showsUserInterface: true, cancelNotification: true),
        ],
      ),
    ),
    payload: jsonEncode(data),
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
  if (!PushService._isAndroid) return;
  final type = message.data['type'];
  if (type == 'coach_call') {
    await _initLocalNotifications();
    await showCoachCallNotification(message.data);
  } else if (type == 'task') {
    await _initLocalNotifications();
    await showTaskNotification(message.data);
  } else if (type == 'call') {
    await _initLocalNotifications();
    await showCallNotification(message.data);
  } else if (type == 'msg') {
    await _initLocalNotifications();
    await showMessageNotification(message.data);
  } else if (type == 'msg_delete') {
    // Сообщение удалили — убрать уведомление с его текстом.
    await _initLocalNotifications();
    await _localNotifications
        .cancel('${message.data['contact_id']}'.hashCode & 0x3fffffff);
  } else if (type == 'call_in') {
    await _initLocalNotifications();
    await showIncomingCallNotification(message.data);
  } else if (type == 'call_end') {
    // Звонящий сдался, а трубку так и не взяли — «пропущенный».
    await _initLocalNotifications();
    await _localNotifications.cancel(PushService._incomingCallNotificationId);
    await _localNotifications.show(
      '${message.data['from']}'.hashCode & 0x3fffffff,
      tr('Пропущенный звонок'),
      tr('Нажмите, чтобы открыть переписку'),
      NotificationDetails(
        android: AndroidNotificationDetails(
            PushService.messageChannelId, tr('Сообщения'),
            importance: Importance.high,
            category: AndroidNotificationCategory.missedCall),
      ),
      payload: '${message.data['from']}',
    );
  }
}

/// Уведомление о задании (новое / снято / выполнено) — тап открывает задание.
/// В фоновом изоляте словарь перевода не загружен, поэтому текст по-русски.
/// Вызов тренера без мессенджера (Android): громкое уведомление с повтором
/// сигнала, пока не откроют или не смахнут.
Future<void> showCoachCallNotification(Map<String, dynamic> data) async {
  final who = '${data['who'] ?? ''}';
  await _localNotifications.show(
    PushService._callNotificationId,
    '${who.isEmpty ? 'Спортсмен' : who}: вызывает вас',
    'Нужна помощь тренера',
    NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.callChannelId,
        tr('Позвать'),
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        additionalFlags: Int32List.fromList([4]),
        timeoutAfter: 120000,
      ),
    ),
    payload: 'coach_call',
  );
}

Future<void> showTaskNotification(Map<String, dynamic> data) async {
  final taskId = '${data['task_id'] ?? ''}';
  final who = '${data['who'] ?? ''}';
  final heading = switch ('${data['kind']}') {
    'done' => '${who.isEmpty ? 'Спортсмен' : who}: задание выполнено',
    'removed' => 'Задание снято тренером',
    'reminder' => 'Напоминание о задании',
    _ => 'Новое задание',
  };
  await _localNotifications.show(
    taskId.hashCode & 0x3fffffff,
    heading,
    '${data['title'] ?? ''}',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        PushService.messageChannelId,
        'Сообщения',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: 'task:$taskId',
  );
}
