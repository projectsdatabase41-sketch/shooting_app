import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/coach_chat_message.dart';
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
    await _ensureProjectSettingsRow();
    return true;
  }

  Future<void> signIn({required String email, required String password}) async {
    _requireBase();
    await _token(
      grant: 'password',
      body: {'email': email.trim(), 'password': password},
      email: email.trim(),
    );
    await _ensureProjectSettingsRow();
  }

  /// Заводит строку-паспорт проекта в облачной `project_settings`, если
  /// её ещё нет — вся RLS в реальной базе держится на
  /// `is_project_owner()`, а та сверяет `auth.uid()` именно с
  /// `owner_user_id` в этой таблице. Без нативной регистрации через
  /// приложение эта строка никогда не появлялась сама (раньше её можно
  /// было завести только вручную через SQL Editor Supabase), и первая
  /// же попытка синхронизации падала с HTTP 403 — не из-за моста, а
  /// из-за того, что владельца проекта попросту не существовало.
  ///
  /// `on_conflict=owner_user_id` + `resolution=ignore-duplicates` —
  /// заводит строку РОВНО ОДИН РАЗ и не трогает её при последующих
  /// входах: настройки (`is_coach`/`is_athlete` и т.п.) могли уже
  /// поменяться, перетирать их дефолтами при каждом логине нельзя.
  ///
  /// Требует отдельную политику на INSERT в `project_settings`
  /// (`with check (owner_user_id = auth.uid())`) — если политика
  /// по-прежнему требует `is_project_owner()` для вставки, это
  /// замкнутый круг (нельзя стать владельцем, не будучи им), и его
  /// может разорвать только ручная вставка первой строки через SQL
  /// Editor. Ошибку здесь поэтому не бросаем — вход должен остаться
  /// успешным, даже если бутстрап не удался; при синхронизации
  /// пользователь всё равно увидит понятный HTTP 403.
  Future<void> _ensureProjectSettingsRow() async {
    final uid = userId;
    if (uid.isEmpty) return;
    final token = await ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('$url/rest/v1/project_settings?on_conflict=owner_user_id'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: jsonEncode({
              'owner_user_id': uid,
              'project_name': 'Стрельба',
              'status': 'active',
              'is_athlete': true,
              'is_coach': false,
              'storage_balance': 'balanced',
            }),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Best-effort: неудача здесь не должна ронять сам вход.
    } finally {
      client.close();
    }
  }

  /// Пароль от аккаунта в отдельном чат-проекте — хранится в
  /// `project_settings.chat_password` ЭТОЙ (личной) базы, не локально,
  /// чтобы чат заводился тем же email без видимой регистрации на любом
  /// устройстве, где уже есть вход в основной аккаунт (см.
  /// `ChatAuthService`/`ChatHomeScreen._ensureChatSession`).
  Future<String?> fetchChatPassword() async {
    final token = await ensureFreshToken();
    if (token == null) return null;
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('$url/rest/v1/project_settings?owner_user_id=eq.$userId&select=chat_password'),
        headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return null;
      final value = decoded.first['chat_password'] as String?;
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> saveChatPassword(String password) async {
    final token = await ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .patch(
            Uri.parse('$url/rest/v1/project_settings?owner_user_id=eq.$userId'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({'chat_password': password}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Не сохранилось — не страшно, следующий silent-вход в чат
      // просто сгенерирует пароль заново (см. _ensureChatSession).
    } finally {
      client.close();
    }
  }

  /// Свой чат-аккаунт — в личную базу, чтобы тренер, подключившийся по
  /// токену, получил его и мог переписываться (см. sql/coach-chat-link.sql).
  Future<void> saveChatIdentity(String chatUserId, String nickname) async {
    final token = await ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .patch(
            Uri.parse('$url/rest/v1/project_settings?owner_user_id=eq.$userId'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({'chat_user_id': chatUserId, 'chat_nickname': nickname}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // колонок ещё нет (SQL не выполнен) — просто без связи с тренером
    } finally {
      client.close();
    }
  }

  /// Тренеры, которым выданы ДЕЙСТВУЮЩИЕ токены и которые уже связали с
  /// ними свой чат-аккаунт.
  Future<List<({String chatUserId, String nickname, String label})>> fetchLinkedCoaches() async {
    final token = await ensureFreshToken();
    if (token == null) return const [];
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('$url/rest/v1/share_grants?select=coach_chat_user_id,coach_chat_nickname,label'
            '&revoked_at=is.null&coach_chat_user_id=not.is.null'),
        headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      final seen = <String>{};
      return [
        for (final r in decoded.cast<Map<String, dynamic>>())
          if (seen.add('${r['coach_chat_user_id']}'))
            (
              chatUserId: '${r['coach_chat_user_id']}',
              nickname: '${r['coach_chat_nickname'] ?? ''}',
              label: '${r['label'] ?? ''}',
            ),
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  /// Тренеры, которым выдан действующий токен, — для «Чата с тренером»
  /// (одна переписка на токен, sql/coach-chat.sql).
  Future<List<({String grantId, String name})>> fetchChatCoaches() async {
    final rows =
        await _rest('GET', 'share_grants?select=id,label,coach_chat_nickname&revoked_at=is.null&order=created_at');
    return [
      for (final r in rows)
        (
          grantId: '${r['id']}',
          name: [r['coach_chat_nickname'], r['label']]
              .map((v) => '${v ?? ''}'.trim())
              .firstWhere((v) => v.isNotEmpty, orElse: () => 'Тренер'),
        ),
    ];
  }

  Future<List<CoachChatMessage>> fetchCoachChat(String grantId) async => [
        for (final r in await _rest('GET', 'coach_chat?grant_id=eq.$grantId&order=created_at.desc&limit=500'))
          coachChatFromRow(r),
      ].reversed.toList();

  Future<void> sendCoachChat(String grantId, String text) =>
      _rest('POST', 'coach_chat', body: {'grant_id': grantId, 'author_role': 'athlete', 'text': text});

  Future<void> deleteCoachChat(String id) => _rest('DELETE', 'coach_chat?id=eq.$id');

  /// Запрос к своей базе от имени владельца; ошибка — исключение с текстом сервера.
  Future<List<Map<String, dynamic>>> _rest(String method, String path, {Object? body}) async {
    final token = await ensureFreshToken();
    if (token == null) throw Exception('Войдите в свою базу (Настройки → Учётная запись)');
    final client = clientFactory();
    try {
      final req = http.Request(method, Uri.parse('$url/rest/v1/$path'))
        ..headers.addAll({
          'apikey': anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        });
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(await client.send(req).timeout(const Duration(seconds: 20)));
      if (res.statusCode >= 400) throw Exception('Сервер ответил ${res.statusCode}: ${res.body}');
      if (res.bodyBytes.isEmpty) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is List ? decoded.cast<Map<String, dynamic>>() : const [];
    } finally {
      client.close();
    }
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

  /// Список таблиц, доступных в личной базе — для подключения таблиц
  /// как справочника ассистенту (пункт 3/8 списка правок: "вводишь
  /// адрес, ключи, жмёшь проверить и получаешь список таблиц").
  ///
  /// Через RPC `list_public_tables` (см. `sql/schema.sql`), а не через
  /// OpenAPI-описание схемы на голом `/rest/v1/` — у части проектов этот
  /// путь отвечает 401 (не общий стандарт, зависит от настроек шлюза
  /// конкретного проекта), тогда как обычный вызов функции идёт тем же
  /// путём и теми же заголовками, что и любой другой запрос в
  /// приложении, и его надёжность уже проверена (`get_shared_*` и т.п.).
  Future<List<String>> fetchTableNames() async {
    _requireBase();
    final token = await ensureFreshToken();
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/list_public_tables'),
            headers: {
              'apikey': anonKey,
              if (token != null) 'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        if (res.statusCode == 404 || res.body.contains('PGRST202') || res.body.contains('PGRST205')) {
          throw const AuthException(
              'Функция list_public_tables не найдена — примените свежий sql/schema.sql к своей базе');
        }
        throw AuthException(_message(res.body));
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      final names = <String>{
        for (final row in decoded)
          if (row is Map && row['table_name'] is String) row['table_name'] as String,
      };
      return names.toList()..sort();
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Не удалось разобрать список таблиц: $e');
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
