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
  /// Аргументы-пустышки для проверки функций. Без них PostgREST отвечает
  /// 404/PGRST202 «функция не найдена», даже когда она есть: у всех функций,
  /// кроме list_public_tables, обязательные параметры (жалоба 26.11 —
  /// «таблицы зелёные, функции красные»).
  static const probes = <String, Map<String, dynamic>>{
    'validate_share_token': {'p_token': 'probe'},
    'get_share_policy': {'p_token': 'probe'},
    'get_shared_table': {'p_token': 'probe', 'p_table': 'x', 'p_limit': 1},
    'coach_create_task': {'p_token': 'probe', 'p_task': <String, dynamic>{}},
    'coach_get_tasks': {'p_token': 'probe'},
    'coach_delete_task': {
      'p_token': 'probe',
      'p_task_id': '00000000-0000-0000-0000-000000000000',
    },
    'athlete_submit_run': {'p_run': <String, dynamic>{}},
    'get_coach_chat': {'p_token': 'probe'},
    'add_coach_chat': {'p_token': 'probe', 'p_text': 'probe'},
  };

  /// Проверка таблиц и функций личной базы.
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
        // Две попытки: одиночный таймаут не должен выглядеть как
        // «таблицы нет» (жалоба 26.11: проверка показывала отсутствующие
        // таблицы при медленной сети).
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final r = await client
                .get(Uri.parse('${auth.url}/rest/v1/$t?select=*&limit=0'), headers: headers)
                .timeout(const Duration(seconds: 35));
            return MapEntry(t, !isMissing(r.statusCode, utf8.decode(r.bodyBytes)));
          } catch (_) {
            if (attempt == 1) return MapEntry(t, false);
          }
        }
        return MapEntry(t, false);
      }

      Future<MapEntry<String, bool>> fn(String f) async {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final r = await client
                .post(Uri.parse('${auth.url}/rest/v1/rpc/$f'), headers: headers, body: jsonEncode(probes[f] ?? const <String, dynamic>{}))
                .timeout(const Duration(seconds: 35));
            // функция есть, если сервер ответил чем угодно, кроме «не найдена»
            // (400 «нет аргументов» / 403 «нужен токен» — значит, она существует)
            return MapEntry(f, !isMissing(r.statusCode, utf8.decode(r.bodyBytes)));
          } catch (_) {
            if (attempt == 1) return MapEntry(f, false);
          }
        }
        return MapEntry(f, false);
      }

      // Не больше 6 запросов одновременно: 34 параллельных запроса к
      // маленькому проекту Supabase упирались в троттлинг и давали ложные
      // «не хватает» (жалоба 26.11).
      Future<List<MapEntry<String, bool>>> limited<T>(
          List<T> items, Future<MapEntry<String, bool>> Function(T) f) async {
        final out = <MapEntry<String, bool>>[];
        for (var i = 0; i < items.length; i += 6) {
          final part = items.skip(i).take(6).map(f);
          out.addAll(await Future.wait(part));
        }
        return out;
      }

      final t = await limited(tables, table);
      final f = await limited(functions, fn);
      return (tables: Map.fromEntries(t), functions: Map.fromEntries(f));
    } finally {
      client.close();
    }
  }
}
