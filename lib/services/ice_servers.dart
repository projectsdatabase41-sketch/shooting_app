import 'remote_config.dart';

/// Общий модуль ICE-серверов для звонков и P2P.
///
/// Порядок: STUN из RemoteConfig → то, что отдал сервер звонков (`/ice`) →
/// TURN из публичного конфига (`webrtc.turn`). Свой TURN выдаёт сервер
/// звонков; конфиг нужен, чтобы подложить рабочий ретранслятор без выпуска
/// новой версии.
///
/// Бесплатный `openrelay.metered.ca` убран: домен отдаёт `192.0.2.1`
/// (тестовый адрес-заглушка), relay-кандидатов не появлялось, а сбор
/// кандидатов только зря тратил время — отчёт 16.11 18:58.
class IceServers {
  IceServers({this.fetch});

  /// Откуда взять серверы от сервера звонков. null — только STUN и конфиг.
  final Future<List<Map<String, dynamic>>> Function()? fetch;

  /// Признак того, кто выдал TURN последним ответом `/ice`: `cloudflare`,
  /// `metered`, `config` (из `webrtc.turn`) или null — ретранслятора нет.
  /// Уходит в отчёт о сбое, чтобы по одной строке было видно причину.
  static String? lastTurnProvider;

  static List<Map<String, dynamic>>? _cache;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _ttl = Duration(minutes: 10);

  static bool hasTurn(List<Map<String, dynamic>> servers) => servers.any((s) {
        final u = s['urls'];
        final list = u is List ? u : [u];
        return list.any((x) => '$x'.startsWith('turn'));
      });

  /// Хосты TURN в коротком виде — для отчёта (`cloudflare`, `openrelay`…).
  static String turnHosts(List<Map<String, dynamic>> servers) {
    final hosts = <String>{};
    for (final s in servers) {
      final u = s['urls'];
      final list = u is List ? u : [u];
      for (final x in list) {
        final v = '$x';
        if (!v.startsWith('turn')) continue;
        final host = Uri.tryParse(v.replaceFirst('turn:', 'https:'))?.host ?? v;
        hosts.add(host.split('.').first);
      }
    }
    return hosts.isEmpty ? 'none' : hosts.join('+');
  }

  /// Серверы без сервера звонков: STUN из конфига + TURN из конфига.
  static List<Map<String, dynamic>> fallback() => <Map<String, dynamic>>[
        {'urls': RemoteConfig.stunServers},
        ...RemoteConfig.turnServers,
      ];

  /// Список для `createPeerConnection`. Кэшируется на 10 минут.
  Future<List<Map<String, dynamic>>> get() async {
    final now = DateTime.now();
    if (_cache != null && now.difference(_cachedAt) < _ttl) return _cache!;

    final get = fetch;
    if (get != null) {
      try {
        final r = await get();
        if (r.isNotEmpty) {
          final configTurn = RemoteConfig.turnServers;
          final fromServer = hasTurn(r);
          final servers = fromServer ? r : [...r, ...configTurn];
          if (fromServer) {
            lastTurnProvider ??= 'server';
          } else if (configTurn.isNotEmpty) {
            lastTurnProvider = 'config';
          }
          _cache = servers;
          _cachedAt = now;
          return servers;
        }
      } catch (_) {}
    }

    final servers = fallback();
    if (hasTurn(servers)) lastTurnProvider = 'config';
    _cache = servers;
    _cachedAt = now;
    return servers;
  }

  /// Сбросить кэш (после смены сети или в тестах).
  static void clearCache() {
    _cache = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
    lastTurnProvider = null;
  }
}
