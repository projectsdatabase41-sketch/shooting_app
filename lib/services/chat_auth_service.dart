import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'chat_settings.dart';
import 'local_db_service.dart';
import 'supabase_auth_service.dart' show AuthException;

/// Учётная запись в ОБЩЕМ чате — отдельная от `SupabaseAuthService`
/// (та ведёт личную базу тренировок пользователя, эта — общий проект
/// для транзита сообщений). Тот же протокол REST/GoTrue, поэтому и код
/// почти дословно повторяет `SupabaseAuthService` — независимая копия,
/// а не общий класс с параметром: две базы физически разные, смешивать
/// их конфигурацию (url/ключ/сессия) в одном месте только запутало бы.
///
/// Внутренний `user_id` нигде не показывается пользователю (решение
/// пользователя) — наружу отдаются только никнейм и `chatCode`,
/// случайный код для добавления в контакты.
class ChatAuthService {
  final LocalDbService db;
  ChatAuthService(this.db);

  http.Client Function() clientFactory = http.Client.new;

  String get url => ChatSettings.url;
  String get anonKey => ChatSettings.anonKey;

  String get userId => _read('chat_user_id');
  String get accessToken => _read('chat_access_token');
  String get refreshToken => _read('chat_refresh_token');
  String get nickname => _read('chat_nickname');
  String get chatCode => _read('chat_code');
  String get avatarBase64 => _read('chat_avatar_base64');

  DateTime? get expiresAt {
    final raw = _read('chat_expires_at');
    return raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  bool get isSignedIn => ChatSettings.isConfigured && accessToken.isNotEmpty;

  Future<String?> ensureFreshToken() async {
    if (!isSignedIn) return null;
    final exp = expiresAt;
    if (exp != null && exp.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return accessToken;
    }
    if (refreshToken.isEmpty) return null;
    try {
      await _token(grant: 'refresh_token', body: {'refresh_token': refreshToken});
      return accessToken;
    } on AuthException {
      signOutLocally();
      return null;
    }
  }

  /// Регистрация: аккаунт в GoTrue общего проекта + строка профиля
  /// (никнейм, случайный код контакта, аватар) в `chat_profiles`.
  /// Подтверждение почты — на усмотрение настроек самого проекта
  /// (решение пользователя: можно вовсе отключить), код здесь на это
  /// не завязан.
  Future<bool> signUp({
    required String nickname,
    required String email,
    required String password,
    String? avatarBase64,
  }) async {
    _requireConfigured();
    final res = await _post('/auth/v1/signup', {
      'email': email.trim(),
      'password': password,
    });
    if (res['access_token'] == null) return false;
    _saveSession(res);
    await _createProfile(nickname: nickname, avatarBase64: avatarBase64);
    return true;
  }

  Future<void> signIn({required String email, required String password}) async {
    _requireConfigured();
    await _token(grant: 'password', body: {'email': email.trim(), 'password': password});
    await _loadOwnProfile();
  }

  void signOutLocally() {
    _write('chat_user_id', '');
    _write('chat_access_token', '');
    _write('chat_refresh_token', '');
    _write('chat_expires_at', '');
    _write('chat_nickname', '');
    _write('chat_code', '');
    _write('chat_avatar_base64', '');
  }

  /// Ищет собеседника по коду контакта — через RPC (`security definer`),
  /// а не прямым чтением `chat_profiles`: обычная строка не должна давать
  /// читать чужие профили целиком, только находить один по точному коду.
  Future<({String userId, String nickname, String? avatarBase64})?> resolveChatCode(String code) async {
    final token = await ensureFreshToken();
    if (token == null) throw const AuthException('Сначала войдите в чат');
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/resolve_chat_code'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'p_code': code.trim()}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return null;
      final row = decoded.first as Map;
      return (
        userId: '${row['user_id']}',
        nickname: '${row['nickname']}',
        avatarBase64: row['avatar_base64'] as String?,
      );
    } finally {
      client.close();
    }
  }

  /// Обновляет аватар в профиле — не меняет никнейм/код.
  Future<void> updateAvatar(String? base64) async {
    final token = await ensureFreshToken();
    if (token == null) throw const AuthException('Сначала войдите в чат');
    final client = clientFactory();
    try {
      final res = await client
          .patch(
            Uri.parse('$url/rest/v1/chat_profiles?user_id=eq.$userId'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({'avatar_base64': base64}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      _write('chat_avatar_base64', base64 ?? '');
    } finally {
      client.close();
    }
  }

  // ---- Внутреннее ----

  void _requireConfigured() {
    if (!ChatSettings.isConfigured) {
      throw const AuthException('Публичный чат ещё не подключён — попробуйте позже');
    }
  }

  /// Код контакта — короткий, читаемый вслух, не похожий на пароль
  /// (`XXXX-XXXX`, без похожих друг на друга символов 0/O/1/I).
  static const String _codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static String _randomChatCode() {
    final rnd = Random.secure();
    String group() => List.generate(4, (_) => _codeAlphabet[rnd.nextInt(_codeAlphabet.length)]).join();
    return '${group()}-${group()}';
  }

  /// Заводит строку в `chat_profiles` — при столкновении по уникальному
  /// `chat_code` (крайне маловероятно, но не исключено) пробует другой
  /// код заново, до нескольких попыток.
  Future<void> _createProfile({required String nickname, String? avatarBase64}) async {
    final token = accessToken;
    for (var attempt = 0; attempt < 5; attempt++) {
      final code = _randomChatCode();
      final client = clientFactory();
      try {
        final res = await client
            .post(
              Uri.parse('$url/rest/v1/chat_profiles'),
              headers: {
                'apikey': anonKey,
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal',
              },
              body: jsonEncode({
                'user_id': userId,
                'nickname': nickname.trim(),
                'chat_code': code,
                'avatar_base64': avatarBase64,
              }),
            )
            .timeout(const Duration(seconds: 20));
        if (res.statusCode < 300) {
          _write('chat_nickname', nickname.trim());
          _write('chat_code', code);
          _write('chat_avatar_base64', avatarBase64 ?? '');
          return;
        }
        // 409/23505 — конфликт уникальности chat_code, пробуем другой.
        if (res.statusCode != 409 && !res.body.contains('23505')) {
          throw AuthException(_message(res.body));
        }
      } finally {
        client.close();
      }
    }
    throw const AuthException('Не удалось создать код контакта, попробуйте ещё раз');
  }

  Future<void> _loadOwnProfile() async {
    final token = accessToken;
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('$url/rest/v1/chat_profiles?user_id=eq.$userId&select=nickname,chat_code,avatar_base64'),
        headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return;
      final row = decoded.first as Map;
      _write('chat_nickname', '${row['nickname'] ?? ''}');
      _write('chat_code', '${row['chat_code'] ?? ''}');
      _write('chat_avatar_base64', '${row['avatar_base64'] ?? ''}');
    } finally {
      client.close();
    }
  }

  Future<void> _token({required String grant, required Map<String, String> body}) async {
    final res = await _post('/auth/v1/token?grant_type=$grant', body);
    if (res['access_token'] == null) throw const AuthException('Сервер не выдал токен');
    _saveSession(res);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, String> body) async {
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url$path'),
            headers: {'apikey': anonKey, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.map((k, v) => MapEntry('$k', v));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Сеть недоступна или чат временно недоступен ($e)');
    } finally {
      client.close();
    }
  }

  void _saveSession(Map<String, dynamic> res) {
    final user = res['user'];
    _write('chat_access_token', '${res['access_token'] ?? ''}');
    _write('chat_refresh_token', '${res['refresh_token'] ?? ''}');
    if (user is Map && user['id'] != null) _write('chat_user_id', '${user['id']}');
    final expiresIn = res['expires_in'];
    if (expiresIn is num) {
      _write('chat_expires_at', DateTime.now().add(Duration(seconds: expiresIn.toInt())).toIso8601String());
    }
  }

  static String _message(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in ['error_description', 'msg', 'message', 'error']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {
      // не JSON — покажем как есть, ниже
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
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
