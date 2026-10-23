import 'dart:convert';
import 'dart:math';

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import 'finals_session_service.dart' show FinalsMember, FinalsRole;

/// Новый случайный токен (зритель публичного финала создаёт себе сам).
String newFinalsToken() => _rand(16);

String _rand(int bytes) {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < bytes; i++) r.nextInt(256)]).replaceAll('=', '');
}

/// Приглашение в финал: временный токен, живёт только пока ведущий не завершил финал.
/// Ничего не пишется в базу: ведущий держит список токенов у себя в памяти и после финала стирает.
class FinalsInvite {
  static const prefix = 'nexus-final:';
  static final _re = RegExp('${RegExp.escape(prefix)}([A-Za-z0-9_=-]+)');
  static RegExp get codePattern => _re;

  final String key; // секретное имя канала финала
  final String token; // личный токен приглашённого
  final String name;
  final FinalsRole role;
  final String? targetId;
  final DateTime expires;

  /// База, на которой ведущий открыл канал (его личная); `null` — публичная база мессенджера.
  final String? url;
  final String? anonKey;
  const FinalsInvite(this.key, this.token, this.name, this.role, this.targetId, this.expires, {this.url, this.anonKey});

  bool get expired => DateTime.now().isAfter(expires);

  /// Участник для экрана гостя: «id пользователя» здесь — токен.
  FinalsMember get member => FinalsMember(key, token, role, targetId, name, 'accepted');

  String encode() => prefix +
      base64Url.encode(utf8.encode(jsonEncode({
        'k': key,
        't': token,
        'n': name,
        'r': role.name,
        if (targetId != null) 'a': targetId,
        'e': expires.millisecondsSinceEpoch ~/ 1000,
        if (url != null && anonKey != null) 'u': url,
        if (url != null && anonKey != null) 'ak': anonKey,
      })));

  /// Ищет код приглашения в тексте (сообщение мессенджера или вставленный текст).
  static FinalsInvite? parse(String text) {
    final m = _re.firstMatch(text);
    if (m == null) return null;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(m.group(1)!)))) as Map<String, dynamic>;
      return FinalsInvite(
        '${j['k']}',
        '${j['t']}',
        '${j['n'] ?? ''}',
        FinalsRole.values.firstWhere((r) => r.name == j['r'], orElse: () => FinalsRole.athlete),
        j['a'] as String?,
        DateTime.fromMillisecondsSinceEpoch((j['e'] as num).toInt() * 1000),
        url: j['u'] as String?,
        anonKey: j['ak'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Список приглашений ведущего. После финала [erase] стирает токены: старые приглашения не сработают.
class FinalsInviteBook {
  /// Секретное имя канала (угадать нельзя).
  final String key = _rand(16);
  final Map<String, FinalsMember> _m = {};

  /// Личная база ведущего для канала финала (нагрузка идёт на неё, а не на общую базу мессенджера).
  /// `null` — у ведущего своей базы нет, используется база мессенджера.
  String? url;
  String? anonKey;

  /// Публичный финал: зрители подключаются сами (до [maxSpectators]), токен им выдаёт не ведущий.
  bool isPublic = false;
  int maxSpectators = 0;

  int get spectators => _m.values.where((m) => m.role == FinalsRole.spectator && m.status == 'accepted').length;
  bool get full => isPublic && spectators >= maxSpectators;

  FinalsInvite create({required FinalsRole role, required String name, String? targetId, Duration ttl = const Duration(hours: 12)}) {
    final token = _rand(16);
    _m[token] = FinalsMember(key, token, role, targetId, name, 'invited');
    return FinalsInvite(key, token, name, role, targetId, DateTime.now().add(ttl), url: url, anonKey: anonKey);
  }

  List<FinalsMember> get members => List.unmodifiable(_m.values);

  /// Гость с токеном подключился. `false` — токена нет (стёрт или чужой).
  bool accept(String token, String name) {
    final m = _m[token];
    if (m == null) {
      // Публичный финал: незнакомый токен — зритель, пока есть места; больше он ничего не может.
      if (!isPublic || token.length < 16 || full) return false;
      _m[token] = FinalsMember(key, token, FinalsRole.spectator, null, name.isEmpty ? 'Зритель' : name, 'accepted');
      return true;
    }
    _m[token] = FinalsMember(m.sessionId, m.userId, m.role, m.targetId, m.name.isEmpty ? name : m.name, 'accepted');
    return true;
  }

  /// Главный из жюри: принявший с наименьшим токеном. Наружу уходит только начало токена —
  /// его хватает, чтобы гость узнал себя, и не хватает, чтобы подделать.
  String? get chiefHint {
    final jury = [for (final m in _m.values) if (m.role == FinalsRole.coach && m.status == 'accepted') m.userId]..sort();
    return jury.isEmpty ? null : hint(jury.first);
  }

  static String hint(String token) => token.length <= 4 ? token : token.substring(0, 4);

  void erase() => _m.clear();
}

/// Какие приглашения уже использованы (по токену), чтобы не предлагать их снова.
class FinalsInviteStore {
  FinalsInviteStore._();
  static const _key = 'finals_invites_seen';

  static const _kEnded = 'finals_invites_ended';

  static Set<String> _read(LocalDbService db, String key) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return rows.isEmpty ? {} : '${rows.first['hex']}'.split(',').where((s) => s.isNotEmpty).toSet();
  }

  static void _write(LocalDbService db, String key, Iterable<String> v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        [key, v.join(',')],
      );

  /// Финал по этому приглашению окончен (ведущий сообщил или отказал): код при уборке стирается.
  static void markEnded(LocalDbService db, String token) {
    final all = {..._read(db, _kEnded), token};
    _write(db, _kEnded, all.length > 60 ? all.skip(all.length - 60) : all);
  }

  /// Стирает из сообщений коды приглашений, которые уже не действуют (срок вышел или финал окончен),
  /// и забывает их токены. Сами сообщения, чаты и контакты (в том числе тренер) не трогаются.
  /// Возвращает число очищенных сообщений.
  static int purge(LocalDbService db) {
    final ended = _read(db, _kEnded);
    final rows = db.db.select("SELECT id, text FROM chat_local_messages WHERE text LIKE ?", ['%${FinalsInvite.prefix}%']);
    var n = 0;
    final dropped = <String>{};
    for (final r in rows) {
      final text = '${r['text']}';
      final i = FinalsInvite.parse(text);
      if (i == null || !(i.expired || ended.contains(i.token))) continue;
      final cleaned = text.replaceAll(FinalsInvite.codePattern, tr('(приглашение в финал больше не действует)'));
      db.db.execute('UPDATE chat_local_messages SET text = ? WHERE id = ?', [cleaned, r['id']]);
      dropped.add(i.token);
      n++;
    }
    if (dropped.isNotEmpty) {
      _write(db, _key, seen(db).difference(dropped));
      _write(db, _kEnded, ended.difference(dropped));
    }
    return n;
  }

  static Set<String> seen(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key]);
    return rows.isEmpty ? {} : '${rows.first['hex']}'.split(',').where((s) => s.isNotEmpty).toSet();
  }

  static void markSeen(LocalDbService db, String token) {
    final all = [...seen(db), token];
    final keep = all.length > 40 ? all.sublist(all.length - 40) : all;
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [_key, keep.join(',')],
    );
  }

  /// Действующие неиспользованные приглашения из входящих сообщений мессенджера.
  static List<FinalsInvite> pending(LocalDbService db) {
    final used = seen(db);
    final rows = db.db.select(
        "SELECT text FROM chat_local_messages WHERE direction = 'incoming' AND text LIKE ? ORDER BY created_at DESC LIMIT 10",
        ['%${FinalsInvite.prefix}%']);
    final out = <FinalsInvite>[];
    for (final r in rows) {
      final i = FinalsInvite.parse('${r['text']}');
      if (i != null && !i.expired && !used.contains(i.token) && !_read(db, _kEnded).contains(i.token) && !out.any((o) => o.token == i.token)) out.add(i);
    }
    return out;
  }
}
