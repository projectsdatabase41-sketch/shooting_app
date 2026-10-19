import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import 'chat_messages_repository.dart';
import 'local_db_service.dart';

/// Папка `Nexus/Chats` в общей памяти телефона: файлы переписок и их история.
/// Удаление приложения её не трогает; после переустановки «Восстановить» читает её
/// и возвращает сообщения с вложениями. Нужен доступ ко всем файлам (включает сам
/// пользователь в настройках Android).
///
/// Раскладка: `Nexus/Chats/<имя>__<id>/contact.json`, `index.jsonl` (по строке на сообщение)
/// и сами вложения `<дата>_<id>_<имя файла>`.
class ChatVault {
  static const _onKey = 'chat_vault_on';
  static const _cursorKey = 'chat_vault_cursor';
  static const _maxRestoreInline = 8 * 1024 * 1024; // крупнее — не грузим в память, открываем с диска
  static final _root = Directory('/storage/emulated/0/Nexus/Chats');

  static bool get supported => Platform.isAndroid;

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static bool isOn(LocalDbService db) => supported && _get(db, _onKey) == '1';
  static void setOn(LocalDbService db, bool v) => _put(db, _onKey, v ? '1' : '0');

  /// Есть ли доступ ко всем файлам; если нет — открывает системную страницу, где его включают.
  static Future<bool> ensureAccess() async {
    if (!supported) return false;
    if (await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
    return (await Permission.storage.request()).isGranted;
  }

  static Future<bool> exists() async {
    try {
      return supported && await _root.exists() && (await _root.list().isEmpty) == false;
    } catch (_) {
      return false;
    }
  }

  static String _safe(String s, {int max = 60}) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();
    return t.isEmpty ? 'chat' : (t.length > max ? t.substring(0, max) : t);
  }

  static String _folderName(String contactId, String? nick) => '${_safe(nick ?? 'chat')}__${_safe(contactId, max: 40)}';

  static Future<void> syncIfOn(LocalDbService db) async {
    if (!isOn(db)) return;
    try {
      if (await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted) await sync(db);
    } catch (_) {}
  }

  /// Дописывает в папку всё новое с прошлого раза (по порядку записи сообщений на телефоне).
  /// Возвращает число сохранённых сообщений.
  static Future<int> sync(LocalDbService db) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    var total = 0;
    while (true) {
      final cursor = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0;
      final rows = db.db.select(
        'SELECT m.rowid AS rid, m.id, m.client_message_id, m.contact_id, c.nickname, m.direction, m.msg_type, m.text, '
        'm.reply_to_preview, m.attachment_name, m.attachment_mime, m.attachment_size, m.attachment_local_path, '
        '(m.attachment_base64 IS NOT NULL) AS has_blob, m.sender_id, m.created_at '
        'FROM chat_local_messages m LEFT JOIN chat_contacts c ON c.id = m.contact_id '
        'WHERE m.rowid > ? ORDER BY m.rowid LIMIT 100',
        [cursor],
      );
      if (rows.isEmpty) break;
      for (final r in rows) {
        final dir = Directory(p.join(_root.path, _folderName('${r['contact_id']}', r['nickname'] as String?)));
        await dir.create(recursive: true);
        final meta = File(p.join(dir.path, 'contact.json'));
        if (!await meta.exists()) {
          await meta.writeAsString(jsonEncode({'id': r['contact_id'], 'nickname': r['nickname']}));
        }
        String? file;
        final name = r['attachment_name'] as String?;
        if (name != null && (r['has_blob'] == 1 || r['attachment_local_path'] != null)) {
          final stamp = '${r['created_at']}'.replaceAll(RegExp(r'[^0-9]'), '');
          final fileName = '${stamp.length > 14 ? stamp.substring(0, 14) : stamp}_${_safe('${r['id']}', max: 8)}_${_safe(name, max: 80)}';
          final target = File(p.join(dir.path, fileName));
          if (!await target.exists()) {
            if (r['has_blob'] == 1) {
              final b = db.db.select('SELECT attachment_base64 AS b FROM chat_local_messages WHERE id = ?', [r['id']]);
              final s = b.isEmpty ? null : b.first['b'] as String?;
              if (s != null) await target.writeAsBytes(base64Decode(s));
            } else {
              final src = File('${r['attachment_local_path']}');
              if (await src.exists()) await src.copy(target.path);
            }
          }
          if (await target.exists()) file = fileName;
        }
        final line = jsonEncode({
          'cid': r['client_message_id'],
          'dir': r['direction'],
          'type': r['msg_type'],
          'text': r['text'],
          'reply': r['reply_to_preview'],
          'name': name,
          'mime': r['attachment_mime'],
          'size': r['attachment_size'],
          'file': file,
          'sender': r['sender_id'],
          'at': r['created_at'],
        });
        await File(p.join(dir.path, 'index.jsonl')).writeAsString('$line\n', mode: FileMode.append, flush: true);
        total++;
        _put(db, _cursorKey, '${r['rid']}');
      }
      if (rows.length < 100) break;
    }
    return total;
  }

  /// Читает папку и добавляет в чат то, чего ещё нет (по client id сообщения).
  /// Нет доступа к файлам — исключение. Возвращает число восстановленных сообщений.
  static Future<int> restore(LocalDbService db, ChatMessagesRepository repo) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    if (!await _root.exists()) return 0;
    var restored = 0;
    final known = {for (final c in repo.listContacts()) c.id};
    await for (final entity in _root.list()) {
      if (entity is! Directory) continue;
      final metaFile = File(p.join(entity.path, 'contact.json'));
      final indexFile = File(p.join(entity.path, 'index.jsonl'));
      if (!await metaFile.exists() || !await indexFile.exists()) continue;
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final contactId = '${meta['id']}';
      if (!known.contains(contactId)) {
        repo.addContact(ChatContact(
            id: contactId, nickname: '${meta['nickname'] ?? 'Контакт'}', chatCode: '', addedAt: DateTime.now()));
        known.add(contactId);
      }
      for (final raw in await indexFile.readAsLines()) {
        if (raw.trim().isEmpty) continue;
        try {
          final e = jsonDecode(raw) as Map<String, dynamic>;
          final cid = '${e['cid']}';
          if (repo.existsByClientId(cid)) continue;
          String? b64, localPath;
          if (e['file'] != null) {
            final f = File(p.join(entity.path, '${e['file']}'));
            if (await f.exists()) {
              if (await f.length() <= _maxRestoreInline) {
                b64 = base64Encode(await f.readAsBytes());
              } else {
                localPath = f.path;
              }
            }
          }
          final type = ChatMessageType.values.where((t) => t.name == e['type']).firstOrNull ?? ChatMessageType.text;
          repo.addMessage(ChatMessage(
            id: const Uuid().v4(),
            clientMessageId: cid,
            contactId: contactId,
            direction: e['dir'] == 'outgoing' ? ChatMessageDirection.outgoing : ChatMessageDirection.incoming,
            status: ChatMessageStatus.delivered,
            type: type,
            text: e['text'] as String?,
            attachmentBase64: b64,
            attachmentName: e['name'] as String?,
            attachmentMime: e['mime'] as String?,
            attachmentSize: (e['size'] as num?)?.toInt(),
            attachmentLocalPath: localPath,
            replyToPreview: e['reply'] as String?,
            senderId: e['sender'] as String?,
            createdAt: DateTime.tryParse('${e['at']}') ?? DateTime.now(),
          ));
          restored++;
        } catch (_) {}
      }
    }
    // Восстановленное уже в папке — не дописывать его туда второй раз.
    final maxRid = db.db.select('SELECT COALESCE(MAX(rowid), 0) AS m FROM chat_local_messages').first['m'];
    _put(db, _cursorKey, '$maxRid');
    return restored;
  }
}
