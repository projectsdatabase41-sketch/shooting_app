import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_db_service.dart';
import 'supabase_auth_service.dart';

/// Резервная копия переписок в личную базу (таблица `chat_backup`, см. sql/schema-v2.sql).
/// Копируется текст и сведения о вложениях, сами вложения — нет. Только новое с прошлого раза.
class ChatBackupService {
  static const _onKey = 'chat_backup_on';
  static const _cursorKey = 'chat_backup_cursor';
  static const _batch = 300;

  final LocalDbService db;
  final SupabaseAuthService auth;
  final http.Client Function() clientFactory;

  ChatBackupService(this.db, this.auth, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static bool isOn(LocalDbService db) => _get(db, _onKey) == '1';
  static void setOn(LocalDbService db, bool v) => _put(db, _onKey, v ? '1' : '0');

  static DateTime? _lastAuto;

  /// Тихий запуск, если копия включена и своя база подключена; не чаще раза в 5 минут.
  static Future<void> runIfOn(LocalDbService db) async {
    if (!isOn(db)) return;
    final last = _lastAuto;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) return;
    _lastAuto = DateTime.now();
    try {
      final auth = SupabaseAuthService(db);
      if (!auth.hasBase) return;
      await ChatBackupService(db, auth).run();
    } catch (_) {}
  }

  /// Сколько сообщений ещё не скопировано.
  static int pending(LocalDbService db) {
    final c = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0;
    return db.db.select('SELECT COUNT(*) AS n FROM chat_local_messages WHERE rowid > ?', [c]).first['n'] as int;
  }

  /// Отправляет новые сообщения в базу. Возвращает, сколько скопировано.
  /// Ошибка сети/доступа — исключение; курсор двигается только после успешной пачки.
  Future<int> run() async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw StateError('not signed in');
    var total = 0;
    final client = clientFactory();
    try {
      while (true) {
        final cursor = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0; // rowid: поздно дошедшие старые сообщения тоже попадут
        final rows = db.db.select(
          'SELECT m.rowid AS rid, m.id, m.contact_id, c.nickname AS contact_name, m.direction, m.msg_type, m.text, m.reply_to_preview, '
          'm.attachment_name, m.attachment_mime, m.attachment_size, m.sender_id, m.call_status, m.edited, m.created_at '
          'FROM chat_local_messages m LEFT JOIN chat_contacts c ON c.id = m.contact_id '
          'WHERE m.rowid > ? ORDER BY m.rowid LIMIT $_batch',
          [cursor],
        );
        if (rows.isEmpty) break;
        final body = [
          for (final r in rows)
            {
              'id': r['id'],
              'contact_id': r['contact_id'],
              'contact_name': r['contact_name'],
              'direction': r['direction'],
              'msg_type': r['msg_type'],
              'text': r['text'],
              'reply_to_preview': r['reply_to_preview'],
              'attachment_name': r['attachment_name'],
              'attachment_mime': r['attachment_mime'],
              'attachment_size': r['attachment_size'],
              'sender_id': r['sender_id'],
              'call_status': r['call_status'],
              'edited': r['edited'] == 1,
              'created_at': _iso('${r['created_at']}'),
            },
        ];
        final res = await client
            .post(
              Uri.parse('${auth.url}/rest/v1/chat_backup?on_conflict=id'),
              headers: {
                'apikey': auth.anonKey,
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Prefer': 'resolution=merge-duplicates,return=minimal',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 40));
        if (res.statusCode >= 400) {
          throw StateError('chat_backup ${res.statusCode}: ${utf8.decode(res.bodyBytes)}');
        }
        total += rows.length;
        _put(db, _cursorKey, '${rows.last['rid']}');
        if (rows.length < _batch) break;
      }
    } finally {
      client.close();
    }
    return total;
  }

  /// SQLite хранит `YYYY-MM-DD HH:MM:SS` (UTC) либо ISO — для базы нужен ISO с часовым поясом.
  static String _iso(String s) {
    final t = DateTime.tryParse(s.contains('T') || s.endsWith('Z') ? s : '${s.replaceFirst(' ', 'T')}Z');
    return (t ?? DateTime.now()).toUtc().toIso8601String();
  }
}
