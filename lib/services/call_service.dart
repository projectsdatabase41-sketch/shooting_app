import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'ice_servers.dart';
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

  /// STUN/TURN от сервера звонков (TURN — временные доступы, выдаёт сервер).
  /// Это «сырой» ответ `/ice`: резервный TURN и STUN из конфига добавляет
  /// `IceServers` (`lib/services/ice_servers.dart`).
  Future<List<Map<String, dynamic>>> iceServers() async {
    try {
      final r = await _send('GET', '/ice') as Map<String, dynamic>;
      // Сервер сам сообщает, чей TURN он выдал (`turnProvider`): cloudflare,
      // metered или null. Без этого в отчётах не отличить «TURN нет» от
      // «TURN есть, но не работает» — отчёт 16.11 18:58.
      final provider = r['turnProvider'];
      IceServers.lastTurnProvider = provider is String && provider.isNotEmpty ? provider : null;
      final servers = (r['iceServers'] as List).cast<Map<String, dynamic>>();

      // Защита месячного бесплатного объёма: Cloudflare даёт 1000 ГБ TURN в
      // месяц, у воркера порог 800 ГБ. Если израсходовано больше 95% порога,
      // TURN не используем вовсе — звонки идут напрямую (или не идут, но
      // счёт не растёт). Так лимит не превысить, даже если воркер ошибётся.
      final usage = await monthUsage();
      final cf = usage?['cloudflare'];
      if (cf is Map) {
        final used = (cf['usedBytes'] as num?)?.toDouble() ?? 0;
        final limit = (cf['limitBytes'] as num?)?.toDouble() ?? 0;
        if (limit > 0 && used >= limit * 0.95) {
          IceServers.lastTurnProvider = null;
          return [for (final s in servers) if (!_hasTurn(s)) s];
        }
      }
      return servers;
    } catch (_) {
      return [
        {
          'urls': ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'],
        },
      ];
    }
  }

  static bool _hasTurn(Map<String, dynamic> server) {
    final u = server['urls'];
    final list = u is List ? u : [u];
    return list.any((x) => '$x'.startsWith('turn'));
  }

  static Map<String, dynamic>? _usageCache;
  static DateTime _usageAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Месячный расход ретранслятора (cloudflare/metered) — из `/usage`.
  /// Кэш 5 минут, чтобы не дёргать сервер на каждый звонок.
  Future<Map<String, dynamic>?> monthUsage({bool fresh = false}) async {
    final now = DateTime.now();
    if (!fresh &&
        _usageCache != null &&
        now.difference(_usageAt) < const Duration(minutes: 5)) {
      return _usageCache;
    }
    try {
      final r = await _send('GET', '/usage') as Map<String, dynamic>;
      _usageCache = r;
      _usageAt = now;
      return r;
    } catch (_) {}
    return _usageCache;
  }

  /// Сообщить серверу, сколько байт прошло через ретранслятор (из него
  /// считается месячный лимит). Зовётся из звонка раз в минуту и в конце.
  Future<void> reportUsage({required String provider, required int bytes}) async {
    if (bytes <= 0) return;
    if (provider != 'cloudflare' && provider != 'metered') return;
    try {
      await _send('POST', '/usage', {'provider': provider, 'bytes': bytes});
      _usageCache = null; // в следующий раз перечитаем свежий расход
    } catch (_) {}
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
