import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../state/app_data_store.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_sync_service.dart';
import 'coach_access_service.dart';
import 'local_db_service.dart';
import 'supabase_auth_service.dart';
import 'supabase_service.dart';
import 'user_profile.dart';

/// Подключение тренера через мессенджер, без ввода кодов и паролей.
///
/// Это обычные сообщения чата с текстом-маркером `NX1:{json}`, которые
/// приложение показывает карточкой:
///  1. `coach_req` спортсмен → тренер: «запрос на добавление» (имя, дата
///     рождения, регион) с кнопками «Добавить / Отказать»;
///  2. `coach_ok` / `coach_no` тренер → спортсмен: ответ;
///  3. `coach_grant` спортсмен → тренер: доступ к базе спортсмена (адрес,
///     ключ приложения, токен); спортсмен выдаёт его сам, когда пришёл
///     `coach_ok`; тренер сохраняет спортсмена в свой список.
///
/// Доступ выдаётся только после согласия тренера, токен идёт по тому же каналу,
/// что и сообщения (сквозного шифрования в мессенджере пока нет).
class CoachLink {
  CoachLink({
    required this.db,
    required this.auth,
    required this.repo,
    required this.sync,
  });

  final LocalDbService db;
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;

  static const prefix = 'NX1:';
  static const _uuid = Uuid();

  static bool isCard(String? text) => text != null && text.startsWith(prefix);

  static Map<String, dynamic>? parse(String? text) {
    if (!isCard(text)) return null;
    try {
      final d = jsonDecode(text!.substring(prefix.length));
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  static String encode(Map<String, dynamic> data) => '$prefix${jsonEncode(data)}';

  /// Короткая подпись для списка контактов / уведомлений вместо сырого JSON.
  static String preview(String? text) {
    final d = parse(text);
    return switch (d?['k']) {
      'coach_req' => tr('Запрос на добавление в спортсмены'),
      'coach_ok' => tr('Тренер принял запрос'),
      'coach_no' => tr('Тренер отклонил запрос'),
      'coach_grant' => tr('Доступ к данным спортсмена'),
      _ => tr('Сообщение'),
    };
  }

  // ---- локальное состояние карточек (отвечено / обработано) ----

  String? state(String clientMessageId) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', ['nx_$clientMessageId']);
    return rows.isEmpty ? null : '${rows.first['hex']}';
  }

  void _setState(String clientMessageId, String v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        ['nx_$clientMessageId', v],
      );

  // ---- спортсмен: запрос тренеру ----

  /// Данные для карточки: имя, дата рождения, регион из профиля.
  Map<String, dynamic> _profileCard() {
    final first = UserProfile.firstNameOf(db), last = UserProfile.lastNameOf(db);
    final name = '$first $last'.trim();
    final d = UserProfile.birthDateOf(db);
    return {
      'k': 'coach_req',
      'name': name.isEmpty ? auth.nickname : name,
      if (d != null) 'birth': '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
      if (UserProfile.birthDateOf(db) == null && UserProfile.birthYearOf(db) != null) 'birth_year': UserProfile.birthYearOf(db),
      'region': UserProfile.regionOf(db),
    };
  }

  Future<void> requestCoach(ChatContact coach) => sync.send(coach.id, encode(_profileCard()));

  // ---- тренер: ответ на запрос ----

  Future<void> answerRequest(ChatMessage request, {required bool accept}) async {
    _setState(request.clientMessageId, accept ? 'yes' : 'no');
    await sync.send(request.contactId, encode({'k': accept ? 'coach_ok' : 'coach_no'}));
  }

  // ---- автоматические шаги ----

  /// Разбирает свежие служебные сообщения и делает автоматические шаги:
  /// спортсмен выдаёт доступ после `coach_ok`, тренер сохраняет спортсмена из
  /// `coach_grant`. Идемпотентно (отметки в локальной базе). Возвращает число
  /// выполненных шагов.
  Future<int> processIncoming(AppDataStore store) async {
    final rows = db.db.select(
      "SELECT * FROM chat_local_messages WHERE text LIKE 'NX1:%' AND direction = 'incoming' "
      'ORDER BY created_at DESC LIMIT 40',
    );
    var done = 0;
    for (final row in rows) {
      final m = ChatMessage.fromRow(row);
      final d = parse(m.text);
      if (d == null || state(m.clientMessageId) == 'done') continue;
      switch (d['k']) {
        case 'coach_ok':
          if (await _grantAccess(store, m)) done++;
        case 'coach_grant':
          if (await _saveAthlete(m, d)) done++;
      }
    }
    return done;
  }

  /// Спортсмен: тренер согласился → создаём токен доступа и отправляем тренеру.
  Future<bool> _grantAccess(AppDataStore store, ChatMessage ok) async {
    final personal = SupabaseAuthService(db);
    if (!personal.isSignedIn) {
      _setState(ok.clientMessageId, 'needs_db'); // карточка подскажет подключить базу
      return false;
    }
    final coach = repo.contactById(ok.contactId);
    try {
      final token = await SupabaseSyncService(personal).createShareToken(
        store,
        athleteLabel: coach?.nickname ?? '',
      );
      await sync.send(
        ok.contactId,
        encode({
          'k': 'coach_grant',
          'url': personal.url,
          'anon': personal.anonKey,
          'token': token,
          'name': _profileCard()['name'],
        }),
      );
      _setState(ok.clientMessageId, 'done');
      return true;
    } catch (_) {
      _setState(ok.clientMessageId, 'error');
      return false;
    }
  }

  /// Тренер: пришёл доступ → сохраняем спортсмена и связываем чат.
  Future<bool> _saveAthlete(ChatMessage grant, Map<String, dynamic> d) async {
    final url = '${d['url'] ?? ''}', anon = '${d['anon'] ?? ''}', token = '${d['token'] ?? ''}';
    if (url.isEmpty || anon.isEmpty || token.isEmpty) {
      _setState(grant.clientMessageId, 'error');
      return false;
    }
    final access = CoachAccessService(db);
    final athlete = CoachAthlete(
      id: _uuid.v4(),
      name: '${d['name'] ?? repo.contactById(grant.contactId)?.nickname ?? ''}',
      url: url,
      anonKey: anon,
      token: token,
    );
    access.saveAthlete(athlete);
    try {
      await access.linkChat(athlete, chatUserId: auth.userId, nickname: auth.nickname);
    } catch (_) {}
    _setState(grant.clientMessageId, 'done');
    return true;
  }
}
