import 'remote_config.dart';

/// Общий модуль ICE-серверов для звонков и P2P.
///
/// Порядок: STUN из RemoteConfig → то, что отдал сервер звонков (`/ice`) →
/// бесплатный резервный TURN. Резерв нужен, потому что без TURN за
/// симметричным NAT оператора пары не составляются вовсе: в отчётах 16.11
/// при 20 host- и 7 srflx-кандидатах состояние оставалось Connecting.
class IceServers {
  IceServers({this.fetch});

  /// Откуда взять серверы от сервера звонков. null — только STUN и резерв.
  final Future<List<Map<String, dynamic>>> Function()? fetch;

  static List<Map<String, dynamic>>? _cache;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _ttl = Duration(minutes: 10);

  /// Бесплатный резервный TURN (Open Relay Project). Свой TURN у проекта
  /// появится позже, поэтому он подставляется, только если среди серверов
  /// нет ни одного turn:-адреса.
  static const freeTurn = <Map<String, dynamic>>[
    {
      'urls': [
        'turn:openrelay.metered.ca:80',
        'turn:openrelay.metered.ca:443',
        'turn:openrelay.metered.ca:443?transport=tcp',
      ],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  static bool hasTurn(List<Map<String, dynamic>> servers) => servers.any((s) {
        final u = s['urls'];
        final list = u is List ? u : [u];
        return list.any((x) => '$x'.startsWith('turn'));
      });

  /// Серверы без сервера звонков: STUN из конфига + резервный TURN.
  static List<Map<String, dynamic>> fallback() => <Map<String, dynamic>>[
        {'urls': RemoteConfig.stunServers},
        ...freeTurn,
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
          final withTurn = hasTurn(r) ? r : [...r, ...freeTurn];
          _cache = withTurn;
          _cachedAt = now;
          return withTurn;
        }
      } catch (_) {}
    }

    final servers = fallback();
    _cache = servers;
    _cachedAt = now;
    return servers;
  }

  /// Сбросить кэш (после смены сети или в тестах).
  static void clearCache() {
    _cache = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
