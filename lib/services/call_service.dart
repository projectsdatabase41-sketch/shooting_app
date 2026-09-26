import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'remote_config.dart';
import '../i18n/i18n.dart';

/// Обращения к серверу звонков (cloud/calls-worker, Cloudflare). Supabase
/// тут не участвует: сервер сам проверяет подпись токена входа в мессенджер.
class CallService {
  CallService(this.auth, {http.Client Function()? clientFactory}) : _client = clientFactory ?? http.Client.new;

  final ChatAuthService auth;
  final http.Client Function() _client;

  static const String defaultUrl = 'https://pusl-calls.pusl-calls.workers.dev';

  /// Адрес можно сменить удалённо (`calls.url` в config/chat-config.json).
  static String get url => RemoteConfig.callsUrl ?? defaultUrl;

  Future<dynamic> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception(tr('Сначала войдите в мессенджер'));
    final c = _client();
    try {
      final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
      final uri = Uri.parse('$url$path');
      final res = await (method == 'GET'
              ? c.get(uri, headers: headers)
              : c.post(uri, headers: headers, body: jsonEncode(body ?? {})))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) throw Exception(tr('Сервер звонков: {statusCode}', {'statusCode': res.statusCode}));
      return jsonDecode(utf8.decode(res.bodyBytes));
    } finally {
      c.close();
    }
  }

  /// FCM-токен устройства — чтобы до него дозвонились, когда приложение закрыто.
  Future<void> registerDevice(String fcmToken) => _send('POST', '/register', {'token': fcmToken});

  /// STUN/TURN для соединения (TURN — временные доступы, выдаёт сервер).
  Future<List<Map<String, dynamic>>> iceServers() async {
    try {
      final r = await _send('GET', '/ice') as Map<String, dynamic>;
      return (r['iceServers'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [
        {
          'urls': ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'],
        },
      ];
    }
  }

  /// Push «входящий звонок» всем устройствам собеседника. Сколько доставлено.
  Future<int> ring({required String callId, required String to, required String name, required bool video}) async {
    final r = await _send('POST', '/call', {'callId': callId, 'to': to, 'name': name, 'video': video}) as Map;
    return (r['delivered'] as num?)?.toInt() ?? 0;
  }

  Future<void> cancel({required String callId, required String to}) async {
    try {
      await _send('POST', '/cancel', {'callId': callId, 'to': to});
    } catch (_) {}
  }

  static Uri roomUri(String callId, String token) =>
      Uri.parse('${url.replaceFirst('https://', 'wss://')}/room/$callId').replace(queryParameters: {'token': token});
}
