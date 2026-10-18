import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/chat_auth_service.dart';

/// Публикация финала в таблицу чемпионов (sql/finals-champions.sql, публичная
/// база мессенджера). Запись попадает в общий список только после подписи
/// тренера.
class ChampionsService {
  final ChatAuthService auth;
  ChampionsService(this.auth);

  /// Сколько выстрелов в своих тренировках на этой мишени достаточно, чтобы
  /// публиковаться без подписи тренера (результат при этом проверяется на
  /// правдоподобие).
  static const minTrainingShotsForSelf = 100;

  /// Отправляет запись; [coachId] — chat-id тренера, который должен подписать.
  /// Возвращает текст ошибки или `null`.
  Future<String?> publish(Map<String, dynamic> record, {required String name, String? coachId, bool selfVerified = false, required Map<String, dynamic> stats, List<double>? protocolShots}) async {
    if (!auth.isSignedIn) return 'Войдите в мессенджер';
    final token = await auth.ensureFreshToken();
    if (token == null) return 'Нет входа в мессенджер';
    final me = (record['standings'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['user'] == true);
    final client = http.Client();
    try {
      Future<http.Response> post(bool withProtocol) => client.post(
            Uri.parse('${auth.url}/rest/v1/finals_champions'),
            headers: {
              'apikey': auth.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({
              'display_name': name,
              'format_id': record['format'],
              'total': me['total'],
              'stats': stats,
              'coach_id': coachId,
              'consent': true,
              if (selfVerified) ...{
                'self_verified': true,
                'coach_signed_at': DateTime.now().toUtc().toIso8601String(),
              },
              // Все выстрелы по порядку: по ним в таблице чемпионов виден протокол.
              if (withProtocol && protocolShots != null) 'protocol': {'shots': protocolShots},
            }),
          ).timeout(const Duration(seconds: 20));
      var res = await post(true);
      // Колонка protocol ещё не создана (SQL не обновлён) — публикуем без неё.
      if (res.statusCode == 400 && protocolShots != null && res.body.contains('protocol')) {
        res = await post(false);
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        return 'Публикация недоступна: аккаунт заблокирован за жалобы или нет прав';
      }
      return res.statusCode < 300 ? null : _explain(res);
    } catch (_) {
      return 'Нет сети';
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> _get(String query) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return const [];
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('${auth.url}/rest/v1/finals_champions?$query'),
        headers: {'apikey': auth.anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      return (jsonDecode(utf8.decode(res.bodyBytes)) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  /// Опубликованные (подписанные) чемпионы формата, лучшие сверху.
  /// Постранично ([offset]) и с поиском по имени ([q]).
  /// [year] — только результаты этого года (по дате публикации).
  Future<List<Map<String, dynamic>>> champions(String formatId, {String q = '', int offset = 0, int? year}) {
    final name = q.trim().isEmpty ? '' : '&display_name=ilike.*${Uri.encodeQueryComponent(q.trim())}*';
    final y = year == null ? '' : '&created_at=gte.$year-01-01&created_at=lt.${year + 1}-01-01';
    return _get('format_id=eq.$formatId&coach_signed_at=not.is.null$name$y&order=total.desc&limit=$pageSize&offset=$offset');
  }

  /// Все опубликованные результаты одного спортсмена (профиль чемпиона), лучшие сверху.
  Future<List<Map<String, dynamic>>> resultsOf(String userId) =>
      _get('user_id=eq.${Uri.encodeQueryComponent(userId)}&coach_signed_at=not.is.null&order=total.desc&limit=200');

  /// Размер страницы: берётся с запасом, потому что список сворачивается по людям.
  static const pageSize = 200;

  /// Записи, ждущие подписи этого тренера.
  Future<List<Map<String, dynamic>>> pendingForMe() =>
      _get('coach_id=eq.${auth.userId}&coach_signed_at=is.null&order=created_at.desc');

  /// Подпись тренера. Возвращает текст ошибки или `null`.
  Future<String?> sign(String id) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return 'Нет входа в мессенджер';
    final client = http.Client();
    try {
      final res = await client.patch(
        Uri.parse('${auth.url}/rest/v1/finals_champions?id=eq.$id'),
        headers: {
          'apikey': auth.anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: jsonEncode({'coach_signed_at': DateTime.now().toUtc().toIso8601String()}),
      ).timeout(const Duration(seconds: 20));
      return res.statusCode < 300 ? null : 'Сервер: ${res.statusCode}';
    } catch (_) {
      return 'Нет сети';
    } finally {
      client.close();
    }
  }

  /// Жалоба на результат (один голос на пользователя). Ошибка или `null`.
  Future<String?> report(String championId) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return 'Нет входа в мессенджер';
    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('${auth.url}/rest/v1/finals_flags'),
        headers: {
          'apikey': auth.anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: jsonEncode({'champion_id': championId}),
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 409) return 'Вы уже отправляли жалобу';
      return res.statusCode < 300 ? null : 'Сервер: ${res.statusCode}';
    } catch (_) {
      return 'Нет сети';
    } finally {
      client.close();
    }
  }

  /// Мои забаненные записи.
  Future<List<Map<String, dynamic>>> myBanned() =>
      _get('user_id=eq.${auth.userId}&banned_until=not.is.null');

  /// Забаненные записи с поданной апелляцией (за них голосуют другие).
  Future<List<Map<String, dynamic>>> appeals() =>
      _get('appeal_requested=eq.true&banned_until=not.is.null&user_id=neq.${auth.userId}');

  Future<String?> _post(String path, Map<String, dynamic> body, {String conflict = 'Уже отправлено'}) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return 'Нет входа в мессенджер';
    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('${auth.url}/rest/v1/$path'),
        headers: {
          'apikey': auth.anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 409) return conflict;
      return res.statusCode < 300 ? null : 'Сервер: ${res.statusCode}';
    } catch (_) {
      return 'Нет сети';
    } finally {
      client.close();
    }
  }

  Future<String?> requestAppeal(String id) => _post('rpc/finals_request_appeal', {'p_id': id});
  Future<String?> voteAppeal(String id) => _post('finals_appeals', {'champion_id': id}, conflict: 'Вы уже голосовали');

  /// Короткое объяснение отказа сервера: код и сообщение базы (если есть).
  String _explain(http.Response res) {
    var detail = '';
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['message'] != null) detail = '${j['message']}';
    } catch (_) {}
    if (detail.length > 140) detail = '${detail.substring(0, 140)}…';
    return detail.isEmpty ? 'Сервер: ${res.statusCode}' : 'Сервер: ${res.statusCode} — $detail';
  }
}
