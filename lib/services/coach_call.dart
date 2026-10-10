import 'dart:convert';

import 'package:http/http.dart' as http;

import 'call_service.dart';
import 'supabase_auth_service.dart';

/// «Позвать тренера» без мессенджера: спортсмен подтверждает вход в СВОЮ базу,
/// сервер звонков (Cloudflare) проверяет его и отправляет push устройствам
/// тренеров, которых тренер сам зарегистрировал в этой базе (тот же путь, что
/// у заданий, `/task-push`). Ключи Firebase хранятся только в воркере.
class CoachCall {
  CoachCall._();

  /// Сколько устройств тренеров получило вызов (0 — никто не зарегистрирован
  /// или нет связи).
  static Future<int> send(SupabaseAuthService auth, {String who = '', http.Client? client}) async {
    final jwt = await auth.ensureFreshToken();
    if (jwt == null) return 0;
    final c = client ?? http.Client();
    try {
      final res = await c
          .post(Uri.parse('${CallService.url}/task-push'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body(auth.url, auth.anonKey, jwt, who)))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return 0;
      return (jsonDecode(utf8.decode(res.bodyBytes))['sent'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    } finally {
      if (client == null) c.close();
    }
  }

  static Map<String, dynamic> body(String db, String key, String jwt, String who) =>
      {'db': db, 'key': key, 'jwt': jwt, 'kind': 'call', 'who': who};
}
