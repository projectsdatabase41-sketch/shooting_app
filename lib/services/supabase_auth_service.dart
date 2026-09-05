import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_db_service.dart';

/// Учётная запись в ЛИЧНОЙ базе Supabase.
///
/// Модель развёртывания (решение пользователя): общей базы нет. У
/// каждого спортсмена свой проект Supabase, у тренера свой. Поэтому
/// «регистрация» здесь — это регистрация не у нас, а в собственной базе
/// пользователя: приложение только передаёт адрес, почту и пароль в его
/// же Supabase.
///
/// ## Почему REST, а не пакет supabase_flutter
///
/// Пакет тянет realtime, websockets и платформенные плагины ради вещей,
/// которых в приложении нет: синхронизация ручная и по кнопке, живых
/// подписок не предполагается. Взамен он добавил бы полтора десятка
/// транзитивных зависимостей в сборку, которую сейчас надо держать
/// собираемой на четырёх платформах. Нужны ровно четыре запроса, и они
/// умещаются в один файл на обычном `http`, который в проекте уже есть.
///
/// Если позже понадобится realtime, менять придётся этот класс, а не
/// вызывающий код.
///
/// ## Что здесь НЕ хранится
///
/// Пароль. Он уходит в Supabase и забывается: в базе остаются только
/// токены, выданные сервером. Пароль пользователя приложение не пишет
/// никуда и не может — это осознанное ограничение.
class SupabaseAuthService {
  final LocalDbService db;

  SupabaseAuthService(this.db);

  /// Клиент подменяется в тестах.
  http.Client Function() clientFactory = http.Client.new;

  // ---- Настройки подключения (лежат в project_settings) ----

  String get url => _read('supabase_url');
  String get anonKey => _read('supabase_anon_key');
  String get email => _read('connected_email');
  String get userId => _read('auth_user_id');
  String get accessToken => _read('auth_access_token');
  String get refreshToken => _read('auth_refresh_token');

  DateTime? get expiresAt {
    final raw = _read('auth_expires_at');
    return raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  /// База указана — можно пытаться входить.
  bool get hasBase => url.isNotEmpty && anonKey.isNotEmpty;

  /// Пользователь вошёл. Истёкший токен здесь тоже считается входом:
  /// его обновляет [ensureFreshToken], а выкидывать человека из
  /// аккаунта из-за просроченного часа — грубость.
  bool get isSignedIn => hasBase && accessToken.isNotEmpty;

  /// Токен, которым можно ходить в базу прямо сейчас, либо null.
  Future<String?> ensureFreshToken() async {
    if (!isSignedIn) return null;
    final exp = expiresAt;
    // Минутный запас: токен, живущий 30 секунд, до конца запроса может
    // и не дожить.
    if (exp != null && exp.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return accessToken;
    }
    if (refreshToken.isEmpty) return null;
    try {
      await _token(grant: 'refresh_token', body: {'refresh_token': refreshToken});
      return accessToken;
    } on AuthException {
      // Refresh-токен протух или отозван — это не ошибка приложения, а
      // нормальный конец сессии. Чистим и просим войти заново.
      signOutLocally();
      return null;
    }
  }

  // ---- Действия пользователя ----

  /// Сохраняет адрес базы. Ключ и адрес пользователь берёт в своём
  /// проекте Supabase (Settings → API).
  void setBase({required String url, required String anonKey}) {
    _write('supabase_url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    _write('supabase_anon_key', anonKey.trim());
  }

  /// Регистрация в личной базе.
  ///
  /// Возвращает `true`, если сразу выдана сессия, и `false`, если
  /// Supabase ждёт подтверждения почты — это его настройка по
  /// умолчанию, и молчать о ней нельзя: человек введёт пароль, ничего
  /// не произойдёт, и виноватым окажется приложение.
  Future<bool> signUp({required String email, required String password}) async {
    _requireBase();
    final res = await _post('/auth/v1/signup', {
      'email': email.trim(),
      'password': password,
    });
    if (res['access_token'] == null) return false;
    _saveSession(res, email: email.trim());
    return true;
  }

  Future<void> signIn({required String email, required String password}) async {
    _requireBase();
    await _token(
      grant: 'password',
      body: {'email': email.trim(), 'password': password},
      email: email.trim(),
    );
  }

  /// Выход: токены стираются с устройства. Локальные тренировки
  /// остаются на месте — база на телефоне живёт своей жизнью и без
  /// облака.
  void signOutLocally() {
    _write('auth_user_id', '');
    _write('auth_access_token', '');
    _write('auth_refresh_token', '');
    _write('auth_expires_at', '');
  }

  /// Полное отключение от базы: вместе с токенами забываются адрес и
  /// ключ.
  void forgetBase() {
    signOutLocally();
    _write('supabase_url', '');
    _write('supabase_anon_key', '');
    _write('connected_email', '');
  }

  /// Проверка, что база отвечает и схема накатана.
  ///
  /// Спрашиваем одну строку из `exercises`: если таблицы нет, Postgrest
  /// отвечает 404 с внятным кодом, и пользователю можно сказать «база
  /// на месте, но таблицы не созданы» вместо общего «ошибка сети».
  Future<String> checkSchema() async {
    _requireBase();
    final token = await ensureFreshToken();
    if (token == null) return 'Сначала войдите в базу';
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('$url/rest/v1/exercises?select=id&limit=1'),
        headers: {
          'apikey': anonKey,
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) return 'База на месте, таблицы созданы';
      if (res.statusCode == 404 || res.body.contains('PGRST205')) {
        return 'База отвечает, но таблиц нет — примените схему (sql/schema.sql)';
      }
      return 'База ответила ${res.statusCode}: ${_message(res.body)}';
    } catch (e) {
      return 'Не удалось достучаться до базы: $e';
    } finally {
      client.close();
    }
  }

  // ---- Внутреннее ----

  void _requireBase() {
    if (!hasBase) {
      throw const AuthException('Сначала укажите адрес базы и ключ');
    }
  }

  Future<void> _token({
    required String grant,
    required Map<String, String> body,
    String? email,
  }) async {
    final res = await _post('/auth/v1/token?grant_type=$grant', body);
    if (res['access_token'] == null) {
      throw const AuthException('Сервер не выдал токен');
    }
    _saveSession(res, email: email);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, String> body) async {
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url$path'),
            headers: {
              'apikey': anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
      if (res.statusCode >= 400) {
        throw AuthException(_message(res.body));
      }
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.map((k, v) => MapEntry('$k', v));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Сеть недоступна или адрес базы неверен ($e)');
    } finally {
      client.close();
    }
  }

  void _saveSession(Map<String, dynamic> res, {String? email}) {
    final user = res['user'];
    _write('auth_access_token', '${res['access_token'] ?? ''}');
    _write('auth_refresh_token', '${res['refresh_token'] ?? ''}');
    if (user is Map && user['id'] != null) _write('auth_user_id', '${user['id']}');
    final expiresIn = res['expires_in'];
    if (expiresIn is num) {
      _write(
        'auth_expires_at',
        DateTime.now().add(Duration(seconds: expiresIn.toInt())).toIso8601String(),
      );
    }
    final mail = email ?? (user is Map ? '${user['email'] ?? ''}' : '');
    if (mail.isNotEmpty) _write('connected_email', mail);
  }

  /// Достаёт человеческий текст из ответа GoTrue. Формат поля плавает
  /// от версии к версии, поэтому перебираем все известные.
  static String _message(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in ['error_description', 'msg', 'message', 'error']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return _translate(v);
        }
      }
    } catch (_) {
      // Не JSON — отдадим как есть, обрезав.
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  /// Несколько самых частых ответов — по-русски. Остальное показывается
  /// как пришло: выдуманный перевод чужой ошибки хуже английского
  /// оригинала.
  static String _translate(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('invalid login credentials')) return 'Неверная почта или пароль';
    if (low.contains('email not confirmed')) return 'Почта не подтверждена — проверьте письмо';
    if (low.contains('user already registered')) return 'Такой пользователь уже есть — войдите';
    if (low.contains('password should be')) return 'Пароль слишком короткий (нужно не меньше 6 символов)';
    if (low.contains('signups not allowed')) return 'В этой базе регистрация выключена';
    return raw;
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

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}
