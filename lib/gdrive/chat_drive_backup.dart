import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_backup_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/local_db_service.dart';
import 'gdrive_service.dart';

/// Копия переписок на Google Диск пользователя в той же раскладке, что и папка телефона
/// (`Nexus/Chats/<имя>__<id>/contact.json`, `index.jsonl`, вложения). Частота — та же, что у
/// копии в базу (`ChatBackupService.mode`). Вложения до 20 МБ.
class ChatDriveBackup {
  static const _onKey = 'chat_gdrive_on';
  static const _cursorKey = 'chat_gdrive_cursor';
  static const _lastKey = 'chat_gdrive_last';
  static const maxFileBytes = 20 * 1024 * 1024;
  static const _maxRestoreInline = 8 * 1024 * 1024;

  final LocalDbService db;
  final GDriveService drive;
  ChatDriveBackup(this.db, this.drive);

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static bool isOn(LocalDbService db) => _get(db, _onKey) == '1' && GDriveService.configured(db);
  static void setOn(LocalDbService db, bool v) => _put(db, _onKey, v ? '1' : '0');
  static DateTime? lastRun(LocalDbService db) => DateTime.tryParse(_get(db, _lastKey) ?? '')?.toLocal();

  static int pending(LocalDbService db) {
    final c = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0;
    return db.db.select('SELECT COUNT(*) AS n FROM chat_local_messages WHERE rowid > ?', [c]).first['n'] as int;
  }

  static DateTime? _lastAuto;

  /// Тихий запуск по выбранной частоте.
  static Future<void> runIfDue(LocalDbService db) async {
    if (!isOn(db)) return;
    final interval = ChatBackupService.mode(db).interval;
    if (interval == null) return;
    final last = [lastRun(db), _lastAuto].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (last != null && DateTime.now().difference(last) < interval) return;
    _lastAuto = DateTime.now();
    try {
      await ChatDriveBackup(db, GDriveService(db)).sync();
    } catch (_) {}
  }

  static String _safe(String s, {int max = 60}) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();
    return t.isEmpty ? 'chat' : (t.length > max ? t.substring(0, max) : t);
  }

  static String _folder(String contactId, String? nick) => '${_safe(nick ?? 'chat')}__${_safe(contactId, max: 40)}';

  /// Отправляет новые сообщения. Возвращает их число.
  Future<int> sync() async {
    var total = 0;
    final folderIds = <String, String>{};
    final lines = <String, List<String>>{};
    while (true) {
      final cursor = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0;
      final rows = db.db.select(
        'SELECT m.rowid AS rid, m.id, m.client_message_id, m.contact_id, c.nickname, m.direction, m.msg_type, m.text, '
        'm.reply_to_preview, m.attachment_name, m.attachment_mime, m.attachment_size, '
        '(m.attachment_base64 IS NOT NULL) AS has_blob, m.sender_id, m.created_at '
        'FROM chat_local_messages m LEFT JOIN chat_contacts c ON c.id = m.contact_id '
        'WHERE m.rowid > ? ORDER BY m.rowid LIMIT 100',
        [cursor],
      );
      if (rows.isEmpty) break;
      int? lastRid;
      try {
        for (final r in rows) {
          final folder = _folder('${r['contact_id']}', r['nickname'] as String?);
          final dirId = folderIds[folder] ??= await _prepareFolder(folder, '${r['contact_id']}', r['nickname'] as String?);
          String? file;
          final name = r['attachment_name'] as String?;
          final size = (r['attachment_size'] as num?)?.toInt();
          if (name != null && r['has_blob'] == 1 && (size == null || size <= maxFileBytes)) {
            final b = db.db.select('SELECT attachment_base64 AS b FROM chat_local_messages WHERE id = ?', [r['id']]);
            final s = b.isEmpty ? null : b.first['b'] as String?;
            if (s != null) {
              final stamp = '${r['created_at']}'.replaceAll(RegExp(r'[^0-9]'), '');
              final fileName = '${stamp.length > 14 ? stamp.substring(0, 14) : stamp}_${_safe('${r['id']}', max: 8)}_${_safe(name, max: 80)}';
              final bytes = base64Decode(s);
              if (bytes.length <= maxFileBytes) {
                await drive.put(dirId, fileName, '${r['attachment_mime'] ?? 'application/octet-stream'}', bytes);
                file = fileName;
              }
            }
          }
          (lines[folder] ??= []).add(jsonEncode({
            'cid': r['client_message_id'],
            'dir': r['direction'],
            'type': r['msg_type'],
            'text': r['text'],
            'reply': r['reply_to_preview'],
            'name': name,
            'mime': r['attachment_mime'],
            'size': size,
            'file': file,
            'sender': r['sender_id'],
            'at': r['created_at'],
          }));
          lastRid = r['rid'] as int;
          total++;
        }
      } finally {
        // Текст индексов дописываем даже при сбое посередине, курсор — по реально обработанным.
        await _flushIndexes(folderIds, lines);
        if (lastRid != null) _put(db, _cursorKey, '$lastRid');
      }
      if (rows.length < 100) break;
    }
    _put(db, _lastKey, DateTime.now().toUtc().toIso8601String());
    return total;
  }

  Future<String> _prepareFolder(String folder, String contactId, String? nick) async {
    final id = await drive.ensurePath('Nexus/Chats/$folder');
    final l = await drive.list(id);
    if (!l.files.any((f) => f.name == 'contact.json')) {
      await drive.put(id, 'contact.json', 'text/plain', utf8.encode(jsonEncode({'id': contactId, 'nickname': nick})));
    }
    return id;
  }

  Future<void> _flushIndexes(Map<String, String> folderIds, Map<String, List<String>> lines) async {
    for (final e in lines.entries.toList()) {
      if (e.value.isEmpty) continue;
      final dirId = folderIds[e.key]!;
      final l = await drive.list(dirId);
      final idx = l.files.where((f) => f.name == 'index.jsonl').firstOrNull;
      var text = '';
      if (idx != null) text = utf8.decode((await drive.get(idx.id)).bytes, allowMalformed: true);
      if (text.isNotEmpty && !text.endsWith('\n')) text += '\n';
      text += '${e.value.join('\n')}\n';
      await drive.put(dirId, 'index.jsonl', 'text/plain', utf8.encode(text), overwriteId: idx?.id);
      lines[e.key] = [];
    }
  }

  /// Читает `Nexus/Chats` на Диске и добавляет в чат то, чего ещё нет. Возвращает число сообщений.
  Future<int> restore(ChatMessagesRepository repo) async {
    final rootId = await drive.ensurePath('Nexus/Chats');
    final known = {for (final c in repo.listContacts()) c.id};
    var restored = 0;
    for (final dir in (await drive.list(rootId)).folders) {
      final l = await drive.list(dir.id);
      final meta = l.files.where((f) => f.name == 'contact.json').firstOrNull;
      final idx = l.files.where((f) => f.name == 'index.jsonl').firstOrNull;
      if (meta == null || idx == null) continue;
      final m = jsonDecode(utf8.decode((await drive.get(meta.id)).bytes)) as Map<String, dynamic>;
      final contactId = '${m['id']}';
      if (!known.contains(contactId)) {
        repo.addContact(ChatContact(id: contactId, nickname: '${m['nickname'] ?? 'Контакт'}', chatCode: '', addedAt: DateTime.now()));
        known.add(contactId);
      }
      final byName = {for (final f in l.files) f.name: f};
      for (final raw in const LineSplitter().convert(utf8.decode((await drive.get(idx.id)).bytes, allowMalformed: true))) {
        if (raw.trim().isEmpty) continue;
        try {
          final e = jsonDecode(raw) as Map<String, dynamic>;
          final cid = '${e['cid']}';
          if (repo.existsByClientId(cid)) continue;
          String? b64;
          final f = e['file'] == null ? null : byName['${e['file']}'];
          if (f != null && f.size <= _maxRestoreInline) b64 = base64Encode((await drive.get(f.id)).bytes);
          repo.addMessage(ChatMessage(
            id: const Uuid().v4(),
            clientMessageId: cid,
            contactId: contactId,
            direction: e['dir'] == 'outgoing' ? ChatMessageDirection.outgoing : ChatMessageDirection.incoming,
            status: ChatMessageStatus.delivered,
            type: ChatMessageType.values.where((t) => t.name == e['type']).firstOrNull ?? ChatMessageType.text,
            text: e['text'] as String?,
            attachmentBase64: b64,
            attachmentName: e['name'] as String?,
            attachmentMime: e['mime'] as String?,
            attachmentSize: (e['size'] as num?)?.toInt(),
            replyToPreview: e['reply'] as String?,
            senderId: e['sender'] as String?,
            createdAt: DateTime.tryParse('${e['at']}') ?? DateTime.now(),
          ));
          restored++;
        } catch (_) {}
      }
    }
    final maxRid = db.db.select('SELECT COALESCE(MAX(rowid), 0) AS m FROM chat_local_messages').first['m'];
    _put(db, _cursorKey, '$maxRid');
    return restored;
  }
}
