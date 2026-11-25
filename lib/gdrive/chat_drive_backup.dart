import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:uuid/uuid.dart';

import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_backup_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/local_db_service.dart';
import 'chat_ai_export.dart';
import 'gdrive_service.dart';

/// Одна запись индекса, ждущая восстановления: чей контакт и что в записи.
class _RestoreItem {
  final String contactId;
  final Map<String, dynamic> entry;
  const _RestoreItem(this.contactId, this.entry);
}

/// Разбор `index.jsonl` в отдельном изоляте: jsonDecode тысяч строк на главном
/// изоляте замораживал интерфейс (отзыв 22.11: после восстановления переписки
/// с Google Диска — «приложение не отвечает»). Функция верхнего уровня, потому
/// что изоляту нужна точка входа, а не замыкание экрана.
List<Map<String, dynamic>> _parseIndexBytes(Uint8List bytes) {
  final out = <Map<String, dynamic>>[];
  for (final raw in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true))) {
    if (raw.trim().isEmpty) continue;
    try {
      final e = jsonDecode(raw);
      if (e is Map<String, dynamic>) out.add(e);
    } catch (_) {}
  }
  return out;
}

/// Копия переписок на Google Диск пользователя в той же раскладке, что и папка телефона
/// (`Nexus/Chats/<имя>__<id>/contact.json`, `index.jsonl`, вложения). Частота — та же, что у
/// копии в базу (`ChatBackupService.mode`). Вложения до 20 МБ.
class ChatDriveBackup {
  static const _onKey = 'chat_gdrive_on';
  static const _cursorKey = 'chat_gdrive_cursor';
  static const _lastKey = 'chat_gdrive_last';
  static const maxFileBytes = 20 * 1024 * 1024;
  static const _maxRestoreInline = 8 * 1024 * 1024;

  /// «Восстановление с Диска уже выполнялось» (дата ISO). Нужно, чтобы импорт не
  /// запускался сам при каждом входе: после первого раза — только по кнопке
  /// (отзыв 22.11: постоянное «приложение не отвечает» после восстановления).
  static const _restoredKey = 'chat_gdrive_restored';

  /// Сколько сообщений вливаем одной пачкой: между пачками интерфейс успевает
  /// отрисовать прогресс «N из M» (отзыв 22.11).
  static const _restoreBatch = 100;

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

  /// Хранение переписок ТОЛЬКО на Диске (отзыв 25.11: в Supabase мало места
  /// на переписки). По умолчанию ВКЛЮЧЕНО — владелец попросил убрать другие
  /// копии и хранить историю на Диске (отзывы 73e72e2e, 75a2fd00, 9a52a30d).
  /// Включён — после успешного экспорта переписки ([ChatAiExport]) старые
  /// строки её транзита удаляются из Supabase (chat_messages), свежие
  /// остаются для доставки.
  static const _driveOnlyKey = 'chat_store_drive_only';
  static bool driveOnlyOn(LocalDbService db) => _get(db, _driveOnlyKey) != '0';
  static void setDriveOnly(LocalDbService db, bool v) => _put(db, _driveOnlyKey, v ? '1' : '0');

  /// Когда переписка последний раз восстанавливалась с Диска (null — ещё ни разу).
  static DateTime? restoredAt(LocalDbService db) => DateTime.tryParse(_get(db, _restoredKey) ?? '')?.toLocal();
  static void markRestored(LocalDbService db) => _put(db, _restoredKey, DateTime.now().toUtc().toIso8601String());

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
      // Режим «только Диск»: вслед за копией выгружаем в формат для ИИ —
      // он же удаляет старые строки транзита из Supabase (см. ChatAiExport).
      if (driveOnlyOn(db)) await ChatAiExport(db, GDriveService(db)).exportAll();
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
  ///
  /// [onProgress] — (восстановлено, всего найдено): экран рисует «N из M».
  /// [cancelled] — кнопка «Отмена»: останавливаемся на границе пачки, уже
  /// налитое остаётся в базе. [force] — повторный запуск по кнопке: без него
  /// после успешного восстановления импорт больше не идёт (отзыв 22.11 —
  /// приложение вставало на повторном разборе всей истории при каждом входе).
  Future<int> restore(
    ChatMessagesRepository repo, {
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
    bool force = false,
  }) async {
    if (!force && restoredAt(db) != null) return 0;
    final rootId = await drive.ensurePath('Nexus/Chats');
    final known = {for (final c in repo.listContacts()) c.id};
    // Уже сохранённые client_message_id — ОДНИМ запросом. Прежний
    // `existsByClientId` на каждое сообщение искал по всей таблице (индекса
    // по client_message_id нет), на тысячах сообщений это минуты работы в
    // главном изоляте — отсюда «приложение не отвечает» (отзыв 22.11).
    final seen = <String>{
      for (final r in db.db.select('SELECT client_message_id AS cid FROM chat_local_messages')) '${r['cid']}'
    };

    // 1. Сначала папки и индексы: список файлов и разбор JSON — в изоляте,
    //    прогресс начинается с честного «всего M».
    final items = <_RestoreItem>[];
    final files = <String, Map<String, DriveItem>>{};
    var stopped = false;
    for (final dir in (await drive.list(rootId)).folders) {
      if (cancelled?.call() == true) {
        stopped = true;
        break;
      }
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
      files[contactId] = {for (final f in l.files) f.name: f};
      final entries = await compute(_parseIndexBytes, (await drive.get(idx.id)).bytes);
      for (final e in entries) {
        final cid = '${e['cid']}';
        if (cid.isEmpty || !seen.add(cid)) continue; // в самом индексе запись тоже могла повториться
        items.add(_RestoreItem(contactId, e));
      }
    }

    final total = items.length;
    onProgress?.call(0, total);
    var restored = 0;
    final batch = <ChatMessage>[];
    // Одна транзакция и ОДИН пересчёт непрочитанных на пачку: `addMessage`
    // делает COUNT(*) по всей таблице на каждое входящее, то есть на
    // восстановлении это O(n²) и главная причина зависания (отзыв 22.11).
    Future<void> flush() async {
      if (batch.isEmpty) return;
      // Считаем РЕАЛЬНО вставленные строки: на Диске могут лежать записи,
      // которые уже есть в базе (дедупликация ниже), и «восстановлено N»
      // не должно их прибавлять.
      restored += _insertBatch(batch);
      batch.clear();
      repo.refreshTotalUnread();
      onProgress?.call(restored, total);
      // Даём кадру отрисоваться: прогресс виден, приложение отвечает.
      await Future<void>.delayed(Duration.zero);
    }

    try {
      for (final it in items) {
        if (cancelled?.call() == true) {
          stopped = true;
          break;
        }
        final e = it.entry;
        String? b64;
        final f = e['file'] == null ? null : files[it.contactId]?['${e['file']}'];
        if (f != null && f.size <= _maxRestoreInline) {
          final bytes = (await drive.get(f.id)).bytes;
          // Фото в base64 — тоже не в главном изоляте: мегабайты кодирования
          // держали UI (отзыв 22.11).
          b64 = await compute(base64Encode, bytes);
        }
        batch.add(ChatMessage(
          id: const Uuid().v4(),
          clientMessageId: '${e['cid']}',
          contactId: it.contactId,
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
        if (batch.length >= _restoreBatch) await flush();
      }
    } finally {
      // Пачка, не дождавшаяся сотни, всё равно сохраняется — при отмене и
      // ошибке уже налитое остаётся (отзыв 22.11).
      await flush();
    }
    // Курсор выкладки и флаг «уже восстановлено» двигаем только после полного
    // прохода: при отмене/сбое оставляем как было, чтобы не потерять из копии
    // сообщения, которые на Диск ещё не уходили (их дошлёт обычная выкладка).
    if (!stopped) {
      // Восстановленное и так лежит на Диске: сдвигаем курсор за него, чтобы
      // следующий запуск не отправлял тысячи старых сообщений заново (это и был
      // повторный «импорт» при каждом входе — отзыв 22.11).
      final maxRid = db.db.select('SELECT COALESCE(MAX(rowid), 0) AS m FROM chat_local_messages').first['m'];
      _put(db, _cursorKey, '$maxRid');
      markRestored(db);
    }
    return restored;
  }

  /// Пачка вставок одной транзакцией, без COUNT(*) на каждую строку.
  /// Колонки — ровно те, что пишет `ChatMessagesRepository.addMessage`; пишем
  /// напрямую, потому что его пересчёт непрочитанных на строку и есть
  /// блокировка UI (отзыв 22.11).
  ///
  /// Возвращает число реально вставленных строк. `INSERT OR IGNORE`, а не
  /// глухой `catch` на каждую запись: дубль по `client_message_id` не должен
  /// ни падать, ни молча терять соседние сообщения пачки.
  int _insertBatch(List<ChatMessage> batch) {
    var inTx = false;
    var inserted = 0;
    try {
      db.db.execute('BEGIN');
      inTx = true;
    } catch (_) {}
    try {
      for (final m in batch) {
        try {
          db.db.execute(
            'INSERT OR IGNORE INTO chat_local_messages '
            '(id, client_message_id, contact_id, direction, text, status, msg_type, '
            'attachment_base64, attachment_name, attachment_mime, attachment_size, '
            'drive_file_id, attachment_local_path, '
            'reply_to_client_message_id, reply_to_preview, download_allowed, sender_id, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              m.id,
              m.clientMessageId,
              m.contactId,
              m.direction.name,
              m.text,
              m.status.name,
              m.type.name,
              m.attachmentBase64,
              m.attachmentName,
              m.attachmentMime,
              m.attachmentSize,
              m.driveFileId,
              m.attachmentLocalPath,
              m.replyToClientMessageId,
              m.replyToPreview,
              m.downloadAllowed ? 1 : 0,
              m.senderId,
              m.createdAt.toUtc().toIso8601String(),
            ],
          );
          inserted += 1;
        } catch (_) {
          // Одна битая запись не должна ронять весь пакет, но и в счёт
          // «восстановлено» она не идёт.
        }
      }
    } finally {
      if (inTx) {
        try {
          db.db.execute('COMMIT');
        } catch (_) {
          // Коммит не прошёл — транзакцию закрываем откатом, иначе она
          // останется открытой и заблокирует следующие записи.
          try {
            db.db.execute('ROLLBACK');
          } catch (_) {}
          inserted = 0;
        }
      }
    }
    return inserted;
  }
}
