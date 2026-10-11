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
}
