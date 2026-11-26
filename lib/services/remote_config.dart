import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_db_service.dart';

/// Удалённые рычаги чата — публичный JSON из репозитория (`config/chat-config.json`).
/// Позволяют замедлить опрос, включить/выключить Realtime и WebRTC или
/// сменить адрес чат-базы БЕЗ выпуска новой версии приложения. Всё, что не
/// пришло или не прошло проверку, — значения по умолчанию (флаги выключены).
/// Секретов здесь быть не должно: файл публичный.
class RemoteConfig {
  static const String url =
      'https://raw.githubusercontent.com/projectsdatabase41-sketch/shooting_app/main/config/chat-config.json';
  static const Duration ttl = Duration(hours: 6);

  static Map<String, dynamic> _v = {};

  /// Только для тестов.
  static void setForTest(Map<String, dynamic> v) => _v = v;

  static dynamic _get(String section, String key) {
    final s = _v[section];
    return s is Map ? s[key] : null;
  }

  /// Множитель интервала опроса, `AdaptivePoller` сам ограничит 0.25–20.
  static double get pollScale {
    final v = _get('poll', 'scale');
    return v is num ? v.toDouble() : 1.0;
  }

  /// ИИ идёт через наш воркер (ключи OpenRouter живут в его секретах).
  static bool get aiProxyEnabled => _get('ai', 'proxy') == true;
  /// Прокси выключен явно (`ai.proxy: false`). Нужно, чтобы старые кэши
  /// конфига (без секции `ai`) не отключали прокси: по умолчанию он включён,
  /// а выключается только явным флагом — это же аварийный выключатель.
  static bool get aiProxyDisabled => _get('ai', 'proxy') == false;

  /// Модели 3D отдаёт воркер из R2 (`models.proxy: true`), а не файлы из
  /// репозитория. Включается после загрузки каталога в R2.
  static bool get modelsProxyEnabled => _get('models', 'proxy') == true;

  static bool get realtimeEnabled => _get('realtime', 'enabled') == true;
  static bool get webrtcEnabled => realtimeEnabled && _get('webrtc', 'enabled') == true;

  /// Сколько секунд тишины в диалоге считать «паузой»: push шлётся только
  /// на первое сообщение после паузы (экономит квоту Edge Function).
  static int get pushQuietSeconds {
    final v = _get('push', 'quietSeconds');
    return v is int ? v.clamp(0, 3600) : 120;
  }

  static List<String> get stunServers {
    final v = _get('webrtc', 'stun');
    final list = v is List ? v.whereType<String>().where((s) => s.startsWith('stun:')).toList() : <String>[];
    return list.isEmpty ? const ['stun:stun.l.google.com:19302'] : list;
  }

  /// TURN из публичного конфига: список `{"urls": [...], "username": "…",
  /// "credential": "…"}`. Нужен, чтобы подложить рабочий ретранслятор БЕЗ
  /// выпуска новой версии приложения: секретов здесь быть не может, только
  /// публичные или временные доступы. Пустой список — TURN только от сервера
  /// звонков.
  static List<Map<String, dynamic>> get turnServers {
    final v = _get('webrtc', 'turn');
    if (v is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in v) {
      if (e is! Map) continue;
      final urls = e['urls'];
      final list = urls is List
          ? urls.whereType<String>().where((s) => s.startsWith('turn')).toList()
          : (urls is String && urls.startsWith('turn') ? <String>[urls] : <String>[]);
      if (list.isEmpty) continue;
      final m = <String, dynamic>{'urls': list};
      if (e['username'] is String) m['username'] = e['username'];
      if (e['credential'] is String) m['credential'] = e['credential'];
      out.add(m);
    }
    return out;
  }

  /// Адрес чат-базы из конфига — только https и *.supabase.co, иначе null
  /// (защита: подменённый конфиг не должен увести приложение на чужой сервер).
  static String? get chatUrl {
    final v = _get('chat', 'url');
    if (v is! String) return null;
    final u = Uri.tryParse(v);
    if (u == null || u.scheme != 'https' || !u.host.endsWith('.supabase.co') || u.path.length > 1) return null;
    return 'https://${u.host}';
  }

  /// Адрес сервера звонков — только https на *.workers.dev.
  static String? get callsUrl {
    final v = _get('calls', 'url');
    if (v is! String) return null;
    final u = Uri.tryParse(v);
    if (u == null || u.scheme != 'https' || !u.host.endsWith('.workers.dev') || u.path.length > 1) return null;
    return 'https://${u.host}';
  }

  static String? get chatAnonKey {
    final v = _get('chat', 'anonKey');
    return v is String && (v.startsWith('sb_publishable_') || v.startsWith('eyJ')) ? v : null;
  }

  /// Подхватывает сохранённую копию (мгновенно, без сети).
  static void loadCached(LocalDbService db) {
    try {
      final rows = db.db.select('SELECT remote_config_json FROM project_settings WHERE id = 1');
      final raw = rows.isEmpty ? null : rows.first['remote_config_json'] as String?;
      if (raw != null && raw.isNotEmpty) _v = _decode(raw);
    } catch (_) {}
  }

  /// Обновляет копию из сети не чаще раза в [ttl]; любая ошибка — молча
  /// остаёмся на том, что есть.
  static Future<void> refresh(LocalDbService db, {http.Client? client, DateTime? now}) async {
    final c = client ?? http.Client();
    try {
      final t = now ?? DateTime.now();
      final rows = db.db.select('SELECT remote_config_at FROM project_settings WHERE id = 1');
      final at = rows.isEmpty ? null : DateTime.tryParse('${rows.first['remote_config_at'] ?? ''}');
      if (at != null && t.difference(at) < ttl) return;
      final res = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final body = utf8.decode(res.bodyBytes);
      final decoded = _decode(body);
      if (decoded.isEmpty) return;
      _v = decoded;
      db.db.execute(
        'INSERT INTO project_settings (id, remote_config_json, remote_config_at) VALUES (1, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET remote_config_json = excluded.remote_config_json, '
        'remote_config_at = excluded.remote_config_at',
        [body, t.toIso8601String()],
      );
    } catch (_) {
    } finally {
      if (client == null) c.close();
    }
  }

  static Map<String, dynamic> _decode(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is Map<String, dynamic> ? d : {};
    } catch (_) {
      return {};
    }
  }
}
