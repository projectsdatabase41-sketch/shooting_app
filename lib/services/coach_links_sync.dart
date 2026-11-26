import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'chat_settings.dart';
import 'coach_access_service.dart';
import 'local_db_service.dart';

/// Зеркало подключений к спортсменам в базе тренера (`coach_athlete_links`).
///
/// Зачем: ИИ тренера, подключённый к его базе, должен видеть список
/// спортсменов (адрес проекта, anon-ключ, share-токен), чтобы сам читать их
/// дневники. Таблица создаётся SQL-скриптом
/// `docs/sql/2026-11-26-coach-athlete-links.sql`.
///
/// Переподключение спортсмена: строка одна на `(owner_user_id, athlete_id)`,
/// upsert перезаписывает адрес/ключ/токен целиком, поэтому старые значения
/// не остаются. Отозванный токен помечается `revoked`.
class CoachLinksSync {
  final LocalDbService db;
  CoachLinksSync(this.db);

  static Map<String, dynamic> payload(CoachAthlete a, String status) => {
        'athlete_id': a.id,
        'name': a.name,
        'supabase_url': a.url,
        'supabase_anon_key': a.anonKey,
        'share_token': a.token,
        'token_status': status,
      };

  Future<String?> upsert(CoachAthlete athlete, {String status = 'unknown'}) async {
    final auth = ChatAuthService(db);
    if (!auth.isSignedIn) return null;
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse(
                '${ChatSettings.url}/rest/v1/coach_athlete_links?on_conflict=owner_user_id,athlete_id'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              // merge-duplicates = перезапись при переподключении спортсмена.
              'Prefer': 'resolution=merge-duplicates,return=minimal',
            },
            body: jsonEncode(payload(athlete, status)),
          )
          .timeout(const Duration(seconds: 20));
      // 404 — таблица ещё не создана (SQL не выполнен): это не ошибка
      // пользователю, просто зеркала пока нет.
      if (res.statusCode == 404) return null;
      if (res.statusCode >= 400) return 'Сервер: ${res.statusCode}';
      return null;
    } catch (_) {
      return 'Нет сети';
    } finally {
      client.close();
    }
  }

  Future<void> remove(String athleteId) async {
    final auth = ChatAuthService(db);
    if (!auth.isSignedIn) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = http.Client();
    try {
      await client.delete(
        Uri.parse(
            '${ChatSettings.url}/rest/v1/coach_athlete_links?athlete_id=eq.${Uri.encodeComponent(athleteId)}'),
        headers: {
          'apikey': ChatSettings.anonKey,
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 20));
    } catch (_) {
      // Удаление зеркала не критично: строка без спортсмена просто устареет.
    } finally {
      client.close();
    }
  }
}
