import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/chat_auth_service.dart';

/// Публикация финала в таблицу чемпионов (sql/finals-champions.sql, публичная
/// база мессенджера). Запись попадает в общий список только после подписи
/// тренера.
class ChampionsService {
  final ChatAuthService auth;
  ChampionsService(this.auth);

  /// Отправляет запись; [coachId] — chat-id тренера, который должен подписать.
  /// Возвращает текст ошибки или `null`.
  Future<String?> publish(Map<String, dynamic> record, {required String name, required String coachId, required Map<String, dynamic> stats}) async {
    if (!auth.isSignedIn) return 'Войдите в мессенджер';
    final token = await auth.ensureFreshToken();
    if (token == null) return 'Нет входа в мессенджер';
    final me = (record['standings'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['user'] == true);
    final client = http.Client();
    try {
      final res = await client.post(
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
        }),
      ).timeout(const Duration(seconds: 20));
      return res.statusCode < 300 ? null : 'Сервер: ${res.statusCode}';
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
  Future<List<Map<String, dynamic>>> champions(String formatId) =>
      _get('format_id=eq.$formatId&coach_signed_at=not.is.null&order=total.desc&limit=50');

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
}
