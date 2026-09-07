import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_db_service.dart';

class CoachAccessException implements Exception {
  final String message;
  const CoachAccessException(this.message);
  @override
  String toString() => message;
}

/// Чтение дневника спортсмена тренером — по токену, в ЧУЖОЙ базе
/// (раздел 14 ТЗ: у каждого спортсмена свой проект Supabase, у тренера
/// свой). Поэтому это не продолжение `SupabaseAuthService` (та ведёт
/// СОБСТВЕННУЮ базу этого устройства) — отдельные адрес, ключ и токен,
/// и никакого входа: RPC на стороне спортсмена сами проверяют токен
/// (`security definer`), апи-ключ нужен только чтобы постучаться в
/// PostgREST вообще.
///
/// На реальной базе (см. docs/db-schema-actual.md) из RPC для этого
/// потока изначально была только `validate_share_token` — проверяет
/// токен и отдаёт `null`/не-`null`, но сама данные не читает. Функции
/// `get_shared_packages`/`get_shared_exercises`/`get_shared_shots`/
/// `get_shared_comments`/`add_shared_comment` дописаны в
/// `sql/schema.sql` (`security definer`, поверх `validate_share_token`,
/// без выборки по владельцу — в этой схеме проект принадлежит ровно
/// одному спортсмену, отдельного `athlete_id` на `share_grants` нет и
/// не нужно).
///
/// `exercises` в этих ответах — РЕАЛЬНАЯ таблица `exercises` (снимок
/// упражнения внутри тренировки, `package_id`+`exercise_name`), а не
/// каталог `exercise_templates`: тренеру для дневника ничего, кроме
/// этого снимка, не нужно.
class CoachAccessService {
  final LocalDbService db;
  CoachAccessService(this.db);

  http.Client Function() clientFactory = http.Client.new;

  String get url => _read('coach_supabase_url');
  String get anonKey => _read('coach_supabase_anon_key');
  String get token => _read('coach_share_token');

  bool get hasConnection => url.isNotEmpty && anonKey.isNotEmpty && token.isNotEmpty;

  void setConnection({required String url, required String anonKey, required String token}) {
    _write('coach_supabase_url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    _write('coach_supabase_anon_key', anonKey.trim());
    _write('coach_share_token', token.trim());
  }

  void forget() {
    _write('coach_supabase_url', '');
    _write('coach_supabase_anon_key', '');
    _write('coach_share_token', '');
  }

  /// Снимки упражнений (реальная таблица `exercises`, не каталог) —
  /// одна строка на тренировку, ключ связи с ней — `package_id`.
  Future<List<Map<String, dynamic>>> fetchExercises() =>
      _rpc('get_shared_exercises', {'p_token': token});

  /// Тренировки спортсмена (`training_packages`).
  Future<List<Map<String, dynamic>>> fetchSessions() =>
      _rpc('get_shared_packages', {'p_token': token});

  /// `sessionId` здесь — id тренировки (`training_packages.id`), он же
  /// id её единственного снимка-упражнения (`exercises.id`): один на
  /// тренировку, отдельным id не заводится — то же самое значение,
  /// которое `shots.exercise_id` и ждёт.
  Future<List<Map<String, dynamic>>> fetchShots(String sessionId) =>
      _rpc('get_shared_shots', {'p_token': token, 'p_exercise_id': sessionId});

  Future<List<Map<String, dynamic>>> fetchComments(String sessionId) =>
      _rpc('get_shared_comments', {'p_token': token, 'p_package_id': sessionId});

  Future<void> addComment({
    required String sessionId,
    required String level,
    String? shotId,
    int? seriesNo,
    required String text,
  }) async {
    await _rpc('add_shared_comment', {
      'p_token': token,
      'p_package_id': sessionId,
      'p_level': level,
      'p_shot_id': shotId,
      'p_series_no': seriesNo,
      'p_text': text,
    });
  }

  Future<List<Map<String, dynamic>>> _rpc(String fn, Map<String, dynamic> args) async {
    if (!hasConnection) {
      throw const CoachAccessException('Не указаны адрес базы, ключ или токен спортсмена');
    }
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/$fn'),
            headers: {
              'apikey': anonKey,
              // RPC-функции проверяют токен сами (security definer) —
              // отдельного входа тренеру не нужно, анонимного ключа
              // достаточно, чтобы постучаться в PostgREST вообще.
              'Authorization': 'Bearer $anonKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw CoachAccessException(_errorMessage(res.body, res.statusCode));
      }
      if (res.bodyBytes.isEmpty) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      return decoded.cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }

  static String _errorMessage(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final msg = decoded['message'] ?? decoded['error_description'] ?? decoded['error'];
        if (msg is String && msg.isNotEmpty) return 'HTTP $status: $msg';
      }
    } catch (_) {
      // тело не JSON — покажем как есть, ниже
    }
    return 'HTTP $status: ${body.length > 200 ? '${body.substring(0, 200)}…' : body}';
  }

  String _read(String column) {
    final rows = db.db.select('SELECT $column FROM project_settings WHERE id = 1');
    if (rows.isEmpty) return '';
    return '${rows.first[column] ?? ''}';
  }

  void _write(String column, String value) {
    db.db.execute(
      'INSERT INTO project_settings (id, $column) VALUES (1, ?) '
      'ON CONFLICT(id) DO UPDATE SET $column = excluded.$column',
      [value],
    );
  }
}
