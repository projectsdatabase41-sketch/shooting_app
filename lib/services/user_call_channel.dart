import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'chat_settings.dart';
import 'realtime_client.dart';
import 'remote_config.dart';

/// Личный канал входящих звонков `ucall:<мой id>`: пока приложение открыто, на нём приходит «звонят» —
/// даже без push (веб на iPhone, телефон без Google-сервисов) и когда нужный чат не открыт.
/// Дальше звонок идёт тем же путём, что и из push (комната на сервере звонков).
/// Политика доступа — sql/chat-call-channel.sql.
class UserCallChannel {
  UserCallChannel._();

  static RealtimeChannelClient? _client;
  static Timer? _retry, _token;
  static bool _wanted = false;
  static int _attempt = 0;
  static ChatAuthService? _auth;
  static void Function(Map<String, dynamic> ring)? _onRing;

  /// Слушаем свой канал. Повторный вызов ничего не ломает.
  static Future<void> start(ChatAuthService auth, void Function(Map<String, dynamic> ring) onRing) async {
    _wanted = true;
    _auth = auth;
    _onRing = onRing;
    if (_client != null || !RemoteConfig.realtimeEnabled || !ChatSettings.isConfigured || !auth.isSignedIn) return;
    final token = await auth.ensureFreshToken();
    if (token == null || !_wanted || _client != null) return;
    final c = RealtimeChannelClient(
      baseUrl: ChatSettings.url,
      anonKey: ChatSettings.anonKey,
      topic: 'ucall:${auth.userId}',
      presenceKey: auth.userId,
    );
    _client = c;
    c.onBroadcast = (event, p) {
      if (event == 'ring') _onRing?.call(p);
    };
    c.onClosed = () {
      if (_client == c) _client = null;
      _scheduleRetry();
    };
    if (await c.join(token)) {
      _attempt = 0;
      _token?.cancel();
      _token = Timer.periodic(const Duration(minutes: 45), (_) async {
        final t = await _auth?.ensureFreshToken();
        if (t != null) _client?.refreshToken(t);
      });
    }
  }

  static void _scheduleRetry() {
    if (!_wanted || _attempt >= 6) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: 5 * (1 << _attempt++)), () {
      final a = _auth, r = _onRing;
      if (a != null && r != null) start(a, r);
    });
  }

  /// Приложение свёрнуто — канал закрываем: звонок дойдёт обычным push.
  static void stop() {
    _wanted = false;
    _retry?.cancel();
    _token?.cancel();
    final c = _client;
    _client = null;
    c?.onClosed = null;
    c?.close();
  }

  /// Звоним в личный канал собеседника (REST-рассылка: подключаться к его каналу не нужно).
  /// `true` — сервер принял; дошло ли, неизвестно (если у собеседника приложение закрыто — не дойдёт).
  static Future<bool> ring(ChatAuthService auth, String peerId,
      {required String callId, required String name, required bool video}) async {
    if (!RemoteConfig.realtimeEnabled || !ChatSettings.isConfigured) return false;
    final token = await auth.ensureFreshToken();
    if (token == null) return false;
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/realtime/v1/api/broadcast'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'messages': [
                {
                  'topic': 'ucall:$peerId',
                  'event': 'ring',
                  'payload': {'callId': callId, 'from': auth.userId, 'name': name, 'video': video},
                  'private': true,
                }
              ]
            }),
          )
          .timeout(const Duration(seconds: 6));
      return res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
