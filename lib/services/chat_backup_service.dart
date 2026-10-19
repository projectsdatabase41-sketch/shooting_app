import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'local_db_service.dart';
import 'supabase_auth_service.dart';

/// Как часто копировать переписки в личную базу.
enum ChatBackupMode {
  off,
  live, // при открытии мессенджера, не чаще раза в 5 минут
  daily,
  weekly;

  Duration? get interval => switch (this) {
        off => null,
        live => const Duration(minutes: 5),
        daily => const Duration(days: 1),
        weekly => const Duration(days: 7),
      };
}

/// Резервная копия переписок в личную базу: таблица `chat_backup` и, если включено,
/// закрытое хранилище `chat-backup` для фото и файлов до [maxFileBytes] (см. sql/schema-v2.sql).
/// Копируется только новое с прошлого раза.
class ChatBackupService {
  static const _modeKey = 'chat_backup_mode';
  static const _filesKey = 'chat_backup_files';
  static const _cursorKey = 'chat_backup_cursor';
  static const _lastKey = 'chat_backup_last';
  static const _batch = 200;
  static const maxFileBytes = 20 * 1024 * 1024;

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

  static ChatBackupMode mode(LocalDbService db) {
    final v = _get(db, _modeKey);
    // прежний переключатель «включено» (до появления режимов) = «постоянно»
    if (v == null && _get(db, 'chat_backup_on') == '1') return ChatBackupMode.live;
    return ChatBackupMode.values.firstWhere((m) => m.name == v, orElse: () => ChatBackupMode.off);
  }

  static void setMode(LocalDbService db, ChatBackupMode m) => _put(db, _modeKey, m.name);

  static bool withFiles(LocalDbService db) => _get(db, _filesKey) == '1';
  static void setWithFiles(LocalDbService db, bool v) => _put(db, _filesKey, v ? '1' : '0');

  static DateTime? lastRun(LocalDbService db) => DateTime.tryParse(_get(db, _lastKey) ?? '')?.toLocal();

  static DateTime? _lastAuto;

  /// Тихий запуск, если пора по выбранной частоте и своя база подключена.
  static Future<void> runIfDue(LocalDbService db) async {
    final interval = mode(db).interval;
    if (interval == null) return;
    final last = [lastRun(db), _lastAuto].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (last != null && DateTime.now().difference(last) < interval) return;
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
  /// Сбой отдельного файла не останавливает копирование текста (у такой записи file_path пуст).
  Future<int> run() async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw StateError('not signed in');
    final files = withFiles(db);
    var total = 0;
    final client = clientFactory();
    try {
      while (true) {
        final cursor = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0; // rowid: поздно дошедшие старые сообщения тоже попадут
        final rows = db.db.select(
          'SELECT m.rowid AS rid, m.id, m.contact_id, c.nickname AS contact_name, m.direction, m.msg_type, m.text, '
          'm.reply_to_preview, m.attachment_name, m.attachment_mime, m.attachment_size, m.attachment_local_path, '
          '(m.attachment_base64 IS NOT NULL) AS has_blob, m.sender_id, m.call_status, m.edited, m.created_at '
          'FROM chat_local_messages m LEFT JOIN chat_contacts c ON c.id = m.contact_id '
          'WHERE m.rowid > ? ORDER BY m.rowid LIMIT $_batch',
          [cursor],
        );
        if (rows.isEmpty) break;
        final body = <Map<String, dynamic>>[];
        for (final r in rows) {
          String? filePath;
          if (files && (r['has_blob'] == 1 || r['attachment_local_path'] != null)) {
            filePath = await _uploadFile(client, token, r);
          }
          body.add({
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
            'file_path': filePath,
            'sender_id': r['sender_id'],
            'call_status': r['call_status'],
            'edited': r['edited'] == 1,
            'created_at': _iso('${r['created_at']}'),
          });
        }
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
      _put(db, _lastKey, DateTime.now().toUtc().toIso8601String());
    } finally {
      client.close();
    }
    return total;
  }

  /// Загружает вложение в закрытое хранилище; `null` — не загружено (слишком большое,
  /// нет файла, сбой). Путь: `<собеседник>/<id сообщения>_<имя>`.
  Future<String?> _uploadFile(http.Client client, String token, Map<String, dynamic> r) async {
    try {
      final size = (r['attachment_size'] as num?)?.toInt();
      if (size != null && size > maxFileBytes) return null;
      List<int>? bytes;
      if (r['has_blob'] == 1) {
        final b = db.db.select('SELECT attachment_base64 AS b FROM chat_local_messages WHERE id = ?', [r['id']]);
        final s = b.isEmpty ? null : b.first['b'] as String?;
        if (s != null) bytes = base64Decode(s);
      } else if (!kIsWeb && r['attachment_local_path'] != null) {
        final f = File('${r['attachment_local_path']}');
        if (await f.exists()) bytes = await f.readAsBytes();
      }
      if (bytes == null || bytes.length > maxFileBytes) return null;
      final name = '${r['attachment_name'] ?? 'file'}'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${Uri.encodeComponent('${r['contact_id']}')}/${r['id']}_$name';
      final res = await client
          .post(
            Uri.parse('${auth.url}/storage/v1/object/chat-backup/$path'),
            headers: {
              'apikey': auth.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': '${r['attachment_mime'] ?? 'application/octet-stream'}',
              'x-upsert': 'true',
            },
            body: bytes,
          )
          .timeout(const Duration(minutes: 2));
      return res.statusCode < 300 ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// SQLite хранит `YYYY-MM-DD HH:MM:SS` (UTC) либо ISO — для базы нужен ISO с часовым поясом.
  static String _iso(String s) {
    final t = DateTime.tryParse(s.contains('T') || s.endsWith('Z') ? s : '${s.replaceFirst(' ', 'T')}Z');
    return (t ?? DateTime.now()).toUtc().toIso8601String();
  }
}
