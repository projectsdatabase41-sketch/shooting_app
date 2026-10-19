import 'dart:convert';

import 'package:http/http.dart' as http;

import 'supabase_auth_service.dart';

/// Проверка, что в личной базе пользователя создано всё нужное приложению
/// (после запуска SQL из lib/db/nexus_personal_db.sql). Список должен совпадать с
/// проверкой внизу этого файла (tools/build_personal_sql.py — TABLES и FUNCTIONS).
///
/// Приложение само SQL выполнить не может: ключ приложения (anon) не даёт права
/// создавать таблицы — это защита Supabase. Поэтому SQL запускается один раз в
/// SQL Editor, а здесь — проверка результата; после сбоя достаточно запустить
/// тот же SQL ещё раз (он идемпотентный) и проверить снова.
class DbSetupCheck {
  static const tables = <String>[
    'project_settings', 'target_faces', 'exercise_templates', 'training_packages', 'exercises', 'file_assets',
    'photo_import_jobs', 'shots', 'remote_athlete_sources', 'archived_packages', 'share_grants', 'share_events',
    'comments', 'training_notes', 'ai_conversation_summaries', 'notes', 'keepalive_log', 'table_docs',
    'tasks', 'task_stages', 'task_steps', 'task_clarifications', 'task_runs', 'task_run_steps', 'task_shots',
    'task_series_notes', 'task_events', 'task_reports', 'task_devices', 'coach_chat', 'devices', 'series', 'shot_samples', 'chat_backup',
  ];

  static const functions = <String>[
    'list_public_tables', 'validate_share_token', 'get_share_policy', 'get_shared_table',
    'coach_create_task', 'coach_get_tasks', 'coach_delete_task', 'athlete_submit_run',
    'get_coach_chat', 'add_coach_chat',
  ];

  /// Адрес SQL Editor проекта: `https://supabase.com/dashboard/project/<ref>/sql/new`.
  static Uri? sqlEditorUri(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    final ref = host.split('.').first;
    if (ref.isEmpty || !host.endsWith('supabase.co')) return null;
    return Uri.parse('https://supabase.com/dashboard/project/$ref/sql/new');
  }

  /// Разбор ответа: нет ли такой таблицы/функции (PostgREST: 404, PGRST205/PGRST202).
  static bool isMissing(int status, String body) =>
      status == 404 || body.contains('PGRST205') || body.contains('PGRST202') || body.contains('42P01');

  /// Результат: имя → есть ли. `tables:` и `functions:` — раздельно.
  static Future<({Map<String, bool> tables, Map<String, bool> functions})> run(
    SupabaseAuthService auth, {
    http.Client Function()? clientFactory,
  }) async {
    final token = await auth.ensureFreshToken();
    final headers = {
      'apikey': auth.anonKey,
      if (token != null) 'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final client = (clientFactory ?? http.Client.new)();
    try {
      Future<MapEntry<String, bool>> table(String t) async {
        try {
          final r = await client
              .get(Uri.parse('${auth.url}/rest/v1/$t?select=*&limit=0'), headers: headers)
              .timeout(const Duration(seconds: 20));
          return MapEntry(t, !isMissing(r.statusCode, utf8.decode(r.bodyBytes)));
        } catch (_) {
          return MapEntry(t, false);
        }
      }

      Future<MapEntry<String, bool>> fn(String f) async {
        try {
          final r = await client
              .post(Uri.parse('${auth.url}/rest/v1/rpc/$f'), headers: headers, body: '{}')
              .timeout(const Duration(seconds: 20));
          // функция есть, если сервер ответил чем угодно, кроме «не найдена»
          // (400 «нет аргументов» / 403 «нужен токен» — значит, она существует)
          return MapEntry(f, !isMissing(r.statusCode, utf8.decode(r.bodyBytes)));
        } catch (_) {
          return MapEntry(f, false);
        }
      }

      final t = await Future.wait(tables.map(table));
      final f = await Future.wait(functions.map(fn));
      return (tables: Map.fromEntries(t), functions: Map.fromEntries(f));
    } finally {
      client.close();
    }
  }
}
