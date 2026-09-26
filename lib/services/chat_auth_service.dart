import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/chat_contact.dart';
import 'chat_settings.dart';
import 'local_db_service.dart';
import '../i18n/i18n.dart';
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
  String get about => _read('chat_about');

  DateTime? get expiresAt {
    final raw = _read('chat_expires_at');
    return raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  bool get isSignedIn => ChatSettings.isConfigured && accessToken.isNotEmpty && !_serverChanged;

  /// Вход сделан на ДРУГОМ сервере мессенджера (сервер переехал, см.
  /// RemoteConfig chat.url) — старый токен тут не действует, нужен новый
  /// вход. Пустая отметка — вход сделан до её появления, то есть на прежнем
  /// сервере frbptucrvmyikencyspu.
  bool get _serverChanged {
    final at = _read('chat_server_url');
    final effective = at.isEmpty ? 'https://frbptucrvmyikencyspu.supabase.co' : at;
    return effective != ChatSettings.url;
  }

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
    // Если проект требует подтверждение почты, `signUp` не успевает
    // завести профиль (RLS не даст вставить строку без настоящей сессии,
    // а её при регистрации ещё не было) — код контакта у пользователя
    // тогда навсегда оставался пустым ("не вижу код, не копируется").
    // Здесь достраиваем профиль по факту первого успешного входа, если
    // его почему-то ещё нет.
    if (nickname.isEmpty) {
      await _createProfile(nickname: email.trim().split('@').first);
    }
  }

  /// Отправляет письмо для сброса пароля (штатный GoTrue-эндпоинт) —
  /// ссылка в письме ведёт на `reset-password.html` (см. web/), который
  /// сам просит новый пароль и обновляет его через `/auth/v1/user`.
  /// Не требует предварительного входа.
  Future<void> requestPasswordReset(String email) async {
    _requireConfigured();
    await _post('/auth/v1/recover', {'email': email.trim()});
  }

  /// 'all' (по умолчанию) — каждое сообщение общего чата, 'replies' —
  /// только ответы на свои сообщения, 'none' — отключены. Кэш локальный
  /// (мгновенно для UI), источник истины — `chat_profiles` на сервере,
  /// его читает Edge Function при рассылке (см. send-chat-push).
  String get globalPushMode {
    final raw = _read('chat_global_push_mode');
    return raw.isEmpty ? 'all' : raw;
  }

  /// Локальный кэш пишется сразу, до сети — та же причина, что у
  /// `updatePrivacyMode` (см. комментарий там): галочка в настройках не
  /// должна ждать ответа сервера, откатывается назад при неудаче.
  Future<void> updateGlobalPushMode(String mode) async {
    final previous = globalPushMode;
    _write('chat_global_push_mode', mode);
    final token = await ensureFreshToken();
    if (token == null) {
      _write('chat_global_push_mode', previous);
      throw AuthException(tr('Сначала войдите в чат'));
    }
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
            body: jsonEncode({'global_push_mode': mode}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        _write('chat_global_push_mode', previous);
        throw AuthException(_message(res.body));
      }
    } finally {
      client.close();
    }
  }

  /// 'all' (по умолчанию) или 'none' — в отличие от общего чата, в личной
  /// переписке любое сообщение и так адресовано лично тебе, отдельного
  /// смысла в варианте "только ответы" здесь нет. "Позвать" эту настройку
  /// не учитывает (см. send-chat-push) — это разовый явный вызов, а не
  /// рядовое сообщение.
  String get personalPushMode {
    final raw = _read('chat_personal_push_mode');
    return raw.isEmpty ? 'all' : raw;
  }

  Future<void> updatePersonalPushMode(String mode) async {
    final previous = personalPushMode;
    _write('chat_personal_push_mode', mode);
    final token = await ensureFreshToken();
    if (token == null) {
      _write('chat_personal_push_mode', previous);
      throw AuthException(tr('Сначала войдите в чат'));
    }
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
            body: jsonEncode({'personal_push_mode': mode}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        _write('chat_personal_push_mode', previous);
        throw AuthException(_message(res.body));
      }
    } finally {
      client.close();
    }
  }

  /// Громкий канал "Позвать" (рингтон устройства + усиленная вибрация,
  /// см. `push_service.dart`) — можно отключить у себя (актуально для
  /// тренера, которому могут звонить чаще и в любое время): тогда вызов
  /// приходит обычным тихим уведомлением вместо звонка поверх всего.
  /// В отличие от personalPushMode это не "заглушить совсем", а именно
  /// понизить громкость одного конкретного типа сигнала.
  bool get callAlertsEnabled => _read('chat_call_alerts_enabled') != '0';

  Future<void> updateCallAlertsEnabled(bool enabled) async {
    final previous = callAlertsEnabled;
    _write('chat_call_alerts_enabled', enabled ? '1' : '0');
    final token = await ensureFreshToken();
    if (token == null) {
      _write('chat_call_alerts_enabled', previous ? '1' : '0');
      throw AuthException(tr('Сначала войдите в чат'));
    }
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
            body: jsonEncode({'call_alerts_enabled': enabled}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        _write('chat_call_alerts_enabled', previous ? '1' : '0');
        throw AuthException(_message(res.body));
      }
    } finally {
      client.close();
    }
  }

  /// 'everyone' (по умолчанию) — как раньше, первый встречный может
  /// просто написать; 'friends_only' — написать может кто угодно, но
  /// это ЗАЯВКА (см. `chat_friends`/`ensureFriendRequest`), сообщения
  /// видны только после её принятия (см. `ChatSyncService.pollIncoming`).
  String get privacyMode {
    final raw = _read('chat_privacy_mode');
    return raw.isEmpty ? 'everyone' : raw;
  }

  /// Локальный кэш пишется СРАЗУ, синхронно, до сетевого запроса —
  /// экран настроек читает `privacyMode` для галочки сразу после вызова,
  /// не дожидаясь ответа сервера (решение пользователя: анимация выбора
  /// не должна тормозить, пока крутится сеть — откатывается назад, если
  /// сохранить не удалось).
  Future<void> updatePrivacyMode(String mode) async {
    final previous = privacyMode;
    _write('chat_privacy_mode', mode);
    final token = await ensureFreshToken();
    if (token == null) {
      _write('chat_privacy_mode', previous);
      throw AuthException(tr('Сначала войдите в чат'));
    }
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
            body: jsonEncode({'privacy_mode': mode}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        _write('chat_privacy_mode', previous);
        throw AuthException(_message(res.body));
      }
    } finally {
      client.close();
    }
  }

  /// Заявка в друзья — вызывается при отправке сообщения новому
  /// собеседнику (см. `ChatSyncService.send`/`sendAttachment`/`sendCall`),
  /// независимо от режима приватности получателя (отправитель его не
  /// знает заранее). Идемпотентно — `ignore-duplicates` даёт звать это
  /// на каждое сообщение без отдельной проверки "уже отправляли".
  /// Ошибка здесь не должна мешать самой отправке сообщения — молча
  /// проглатывается, заявка просто не создастся в этот раз.
  Future<void> ensureFriendRequest(String contactId) async {
    final token = await ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('$url/rest/v1/chat_friends'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal,resolution=ignore-duplicates',
            },
            body: jsonEncode({'requester_id': userId, 'addressee_id': contactId}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // необязательно
    } finally {
      client.close();
    }
  }

  /// 'accepted' — можно показывать сообщения от [otherId] (в любую
  /// сторону — не важно, кто кому писал первым), иначе они остаются
  /// ждать на сервере, пока заявку не примут (см. `pollIncoming`).
  Future<String?> friendStatusWith(String otherId) async {
    final token = await ensureFreshToken();
    if (token == null) return null;
    final client = clientFactory();
    try {
      final res = await client
          .get(
            Uri.parse('$url/rest/v1/chat_friends').replace(queryParameters: {
              'select': 'status',
              'or': '(and(requester_id.eq.$userId,addressee_id.eq.$otherId),'
                  'and(requester_id.eq.$otherId,addressee_id.eq.$userId))',
            }),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return null;
      for (final row in decoded) {
        if (row['status'] == 'accepted') return 'accepted';
      }
      return 'pending';
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Входящие заявки (я — адресат, статус ещё не принят) — экран
  /// "Приватность" (см. `ChatPrivacyScreen`).
  Future<List<({String userId, String nickname, String? avatarBase64, DateTime createdAt})>>
      fetchFriendRequests() async {
    final token = await ensureFreshToken();
    if (token == null) return const [];
    final client = clientFactory();
    try {
      final res = await client
          .get(
            Uri.parse('$url/rest/v1/chat_friends').replace(queryParameters: {
              'select': 'requester_id,created_at',
              'addressee_id': 'eq.$userId',
              'status': 'eq.pending',
            }),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return const [];
      final ids = decoded.map((r) => '${r['requester_id']}').toList();
      final profiles = await resolveProfiles(ids);
      return [
        for (final row in decoded)
          (
            userId: '${row['requester_id']}',
            nickname: profiles['${row['requester_id']}']?.nickname ?? '—',
            avatarBase64: profiles['${row['requester_id']}']?.avatarBase64,
            createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
          ),
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  Future<void> acceptFriendRequest(String requesterId) async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Сначала войдите в чат'));
    final client = clientFactory();
    try {
      final res = await client
          .patch(
            Uri.parse('$url/rest/v1/chat_friends').replace(queryParameters: {
              'requester_id': 'eq.$requesterId',
              'addressee_id': 'eq.$userId',
            }),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({'status': 'accepted'}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
    } finally {
      client.close();
    }
  }

  /// Отклонить заявку — убирает саму заявку и подчищает уже пришедшие,
  /// но так и не показанные сообщения этого отправителя (см.
  /// `pollIncoming`: пока заявка не принята, они остаются на сервере
  /// нетронутыми) — иначе они молча копились бы там навсегда.
  Future<void> declineFriendRequest(String requesterId) async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Сначала войдите в чат'));
    final client = clientFactory();
    try {
      final res = await client
          .delete(
            Uri.parse('$url/rest/v1/chat_friends').replace(queryParameters: {
              'requester_id': 'eq.$requesterId',
              'addressee_id': 'eq.$userId',
            }),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      await client
          .delete(
            Uri.parse('$url/rest/v1/chat_messages').replace(queryParameters: {
              'sender_id': 'eq.$requesterId',
              'recipient_id': 'eq.$userId',
            }),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
    } finally {
      client.close();
    }
  }

  /// Принятые заявки (в любую сторону) — переживают переустановку
  /// приложения и смену телефона, в отличие от `chat_contacts` (только
  /// на устройстве): при входе на новом устройстве список подтягивается
  /// заново в локальные контакты (см. `_ChatHomeScreenState._syncFriends`).
  Future<List<({String userId, String nickname, String? avatarBase64, String about})>> listFriends() async {
    final token = await ensureFreshToken();
    if (token == null) return const [];
    final client = clientFactory();
    try {
      final res = await client
          .get(
            Uri.parse('$url/rest/v1/chat_friends').replace(queryParameters: {
              'select': 'requester_id,addressee_id',
              'status': 'eq.accepted',
              'or': '(requester_id.eq.$userId,addressee_id.eq.$userId)',
            }),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return const [];
      final otherIds = decoded
          .map((r) => '${r['requester_id']}' == userId ? '${r['addressee_id']}' : '${r['requester_id']}')
          .toSet()
          .toList();
      final profiles = await resolveProfiles(otherIds);
      return [
        for (final id in otherIds)
          (
            userId: id,
            nickname: profiles[id]?.nickname ?? '—',
            avatarBase64: profiles[id]?.avatarBase64,
            about: profiles[id]?.about ?? '',
          ),
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  /// Меняет никнейм — например, если он достался по умолчанию из почты
  /// (см. комментарий в `signIn`) и пользователь хочет вписать свой.
  Future<void> updateNickname(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    await _patchProfile({'nickname': trimmed});
    _write('chat_nickname', trimmed);
  }

  /// Короткая строка о себе (клуб, город, дисциплина) — видна контактам.
  Future<void> updateAbout(String value) async {
    final trimmed = value.trim();
    await _patchProfile({'about': trimmed});
    _write('chat_about', trimmed);
  }

  /// Изменение своего профиля. Сервер возвращает изменённую строку: пусто —
  /// значит профиль не нашёлся (сохранённый вход от другого сервера/аккаунта),
  /// раньше это проходило молча и ник «не сохранялся».
  Future<void> _patchProfile(Map<String, dynamic> body) async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Вход в чат устарел — выйдите из чата и войдите снова'));
    final client = clientFactory();
    try {
      final res = await client
          .patch(
            Uri.parse('$url/rest/v1/chat_profiles?user_id=eq.$userId'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=representation',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      final rows = jsonDecode(utf8.decode(res.bodyBytes));
      if (rows is List && rows.isEmpty) {
        throw AuthException(tr('Профиль на сервере не найден — выйдите из чата и войдите снова'));
      }
    } finally {
      client.close();
    }
  }

  /// Профили по списку id (ник, аватар, «о себе») — RPC `resolve_profiles`
  /// не отдаёт chat_code. Ошибка сети — пустой результат.
  Future<Map<String, ({String nickname, String? avatarBase64, String about})>> resolveProfiles(
      List<String> ids) async {
    if (ids.isEmpty) return {};
    final token = await ensureFreshToken();
    if (token == null) return {};
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/resolve_profiles'),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'p_ids': ids}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return {};
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return {};
      return {
        for (final row in decoded.cast<Map<String, dynamic>>())
          '${row['user_id']}': (
            nickname: '${row['nickname']}',
            avatarBase64: row['avatar_base64'] as String?,
            about: '${row['about'] ?? ''}',
          ),
      };
    } catch (_) {
      return {};
    } finally {
      client.close();
    }
  }

  /// Вызов RPC чат-базы; ошибка сервера — [AuthException] с его текстом.
  Future<dynamic> _rpc(String name, Map<String, dynamic> body) async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Сначала войдите в чат'));
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/$name'),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      return res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } finally {
      client.close();
    }
  }

  /// Отметиться «в сети» и получить время появления друзей; null — сбой сети.
  Future<Map<String, DateTime>?> presence() async {
    try {
      final rows = await _rpc('chat_presence', {});
      if (rows is! List) return null;
      return {
        for (final r in rows)
          if (DateTime.tryParse('${r['last_seen']}') case final t?) '${r['user_id']}': t,
      };
    } catch (_) {
      return null;
    }
  }

  /// Код контакта собеседника — сервер отдаёт его только другу или
  /// участнику общей группы (sql/chat-contact-code.sql); иначе пусто.
  Future<String> codeOf(String userId) async {
    try {
      return '${await _rpc('chat_code_of', {'p_user': userId}) ?? ''}';
    } catch (_) {
      return '';
    }
  }

  /// Все участники мессенджера (кроме себя) — по имени, «о себе» или точному
  /// коду контакта; пустой запрос — все по алфавиту. Постранично по [limit].
  Future<List<({String userId, String nickname, String? avatarBase64, String about})>> searchProfiles(
    String query, {
    int offset = 0,
    int limit = 30,
  }) async {
    final rows = await _rpc('search_profiles', {'p_query': query.trim(), 'p_limit': limit, 'p_offset': offset});
    if (rows is! List) return const [];
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        (
          userId: '${r['user_id']}',
          nickname: '${r['nickname']}',
          avatarBase64: r['avatar_base64'] as String?,
          about: '${r['about'] ?? ''}',
        ),
    ];
  }

  /// Мои группы с участниками (для локального списка диалогов).
  Future<List<ChatContact>> myGroups() async {
    try {
      final rows = await _rpc('my_groups', {});
      if (rows is! List) return const [];
      return [
        for (final r in rows.cast<Map<String, dynamic>>())
          ChatContact(
            id: '${r['id']}',
            nickname: '${r['name']}',
            chatCode: '',
            avatarBase64: r['avatar_base64'] as String?,
            about: '${r['about'] ?? ''}',
            addedAt: DateTime.now(),
            isGroup: true,
            color: '${r['color'] ?? ''}',
            members: [
              for (final m in (r['members'] as List? ?? const []))
                ChatGroupMember.fromJson(Map<String, dynamic>.from(m as Map)),
            ],
          ),
      ];
    } catch (_) {
      return const []; // групп ещё нет на сервере (sql/chat-groups.sql не выполнен) или нет сети
    }
  }

  Future<String> createGroup({
    required String name,
    String about = '',
    String color = '',
    String? avatarBase64,
    required List<String> memberIds,
  }) async =>
      '${await _rpc('create_group', {
            'p_name': name,
            'p_about': about,
            'p_color': color,
            'p_avatar': avatarBase64,
            'p_member_ids': memberIds,
          })}';

  Future<void> updateGroup(String groupId,
          {required String name, String about = '', String color = '', String? avatarBase64}) =>
      _rpc('update_group', {'p_group': groupId, 'p_name': name, 'p_about': about, 'p_color': color, 'p_avatar': avatarBase64});

  Future<void> addGroupMembers(String groupId, List<String> ids) =>
      _rpc('add_group_members', {'p_group': groupId, 'p_member_ids': ids});

  /// Убрать участника; свой id — выйти из группы.
  Future<void> removeGroupMember(String groupId, String userId) =>
      _rpc('remove_group_member', {'p_group': groupId, 'p_user': userId});

  Future<void> setGroupRole(String groupId, String userId, String role) =>
      _rpc('set_group_role', {'p_group': groupId, 'p_user': userId, 'p_role': role});

  void signOutLocally() {
    _write('chat_user_id', '');
    _write('chat_access_token', '');
    _write('chat_refresh_token', '');
    _write('chat_expires_at', '');
    _write('chat_nickname', '');
    _write('chat_code', '');
    _write('chat_avatar_base64', '');
    _write('chat_about', '');
  }

  /// Удаляет чат-аккаунт целиком на сервере (профиль, друзья/заявки,
  /// push-токены, сообщения — всё каскадом по внешним ключам, см.
  /// `delete_own_chat_account` в sql/chat-schema.sql), затем выходит
  /// локально. Необратимо — подтверждение спрашивает вызывающий экран.
  Future<void> deleteAccount() async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Сначала войдите в чат'));
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('$url/rest/v1/rpc/delete_own_chat_account'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw AuthException(_message(res.body));
      signOutLocally();
    } finally {
      client.close();
    }
  }

  /// Ищет собеседника по коду контакта — через RPC (`security definer`),
  /// а не прямым чтением `chat_profiles`: обычная строка не должна давать
  /// читать чужие профили целиком, только находить один по точному коду.
  Future<({String userId, String nickname, String? avatarBase64, String about})?> resolveChatCode(String code) async {
    final token = await ensureFreshToken();
    if (token == null) throw AuthException(tr('Сначала войдите в чат'));
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
        about: '${row['about'] ?? ''}',
      );
    } finally {
      client.close();
    }
  }

  /// Обновляет аватар в профиле — не меняет никнейм/код.
  Future<void> updateAvatar(String? base64) async {
    await _patchProfile({'avatar_base64': base64});
    _write('chat_avatar_base64', base64 ?? '');
  }


  // ---- Внутреннее ----

  void _requireConfigured() {
    if (!ChatSettings.isConfigured) {
      throw AuthException(tr('Публичный чат ещё не подключён — попробуйте позже'));
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
    throw AuthException(tr('Не удалось создать код контакта, попробуйте ещё раз'));
  }

  Future<void> _loadOwnProfile() async {
    final token = accessToken;
    final client = clientFactory();
    try {
      Future<http.Response> load(String columns) => client.get(
            Uri.parse('$url/rest/v1/chat_profiles?user_id=eq.$userId&select=$columns'),
            headers: {'apikey': anonKey, 'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 20));
      var res = await load('nickname,chat_code,avatar_base64,about');
      // Колонки about на сервере ещё нет (sql/chat-schema.sql не накатан) —
      // профиль всё равно должен загрузиться.
      if (res.statusCode >= 400) res = await load('nickname,chat_code,avatar_base64');
      if (res.statusCode >= 400) return;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return;
      final row = decoded.first as Map;
      _write('chat_nickname', '${row['nickname'] ?? ''}');
      _write('chat_code', '${row['chat_code'] ?? ''}');
      _write('chat_avatar_base64', '${row['avatar_base64'] ?? ''}');
      _write('chat_about', '${row['about'] ?? ''}');
    } finally {
      client.close();
    }
  }

  Future<void> _token({required String grant, required Map<String, String> body}) async {
    final res = await _post('/auth/v1/token?grant_type=$grant', body);
    if (res['access_token'] == null) throw AuthException(tr('Сервер не выдал токен'));
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
      throw AuthException(tr('Сеть недоступна или чат временно недоступен ({e})', {'e': e}));
    } finally {
      client.close();
    }
  }

  void _saveSession(Map<String, dynamic> res) {
    final user = res['user'];
    _write('chat_server_url', ChatSettings.url);
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
