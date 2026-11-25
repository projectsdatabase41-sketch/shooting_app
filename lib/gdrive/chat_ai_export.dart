import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

// Локальные файлы вложений читаются только на мобильных/десктопе; отдельный
// файл нужен, чтобы `dart:io` не попадал в веб-сборку (deploy-web).
import 'chat_ai_export_local_web.dart'
    if (dart.library.io) 'chat_ai_export_local_io.dart';

import '../i18n/i18n.dart' show tr;
import '../logic/friendly_error.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_settings.dart';
import '../services/local_db_service.dart';
import 'chat_drive_backup.dart';
import 'gdrive_service.dart';

/// Исключение экспорта: наружу идёт понятный текст, а не «молчаливый» сбой.
class AiExportException implements Exception {
  final String message;
  AiExportException(this.message);
  @override
  String toString() => message;
}

/// Итог выгрузки одной переписки на Диск (Nexus/Chats/<chatId>/).
class AiChatExport {
  final String chatId;
  final String folder;

  /// Добавлено строк в messages.jsonl (по id — только новые).
  final int newMessages;

  /// Залито вложений в media/ (уже лежащие не перезаливаются).
  final int newMedia;

  /// Удалено старых строк из chat_messages (режим «только Диск»); сервер
  /// число удалённого не отдаёт, поэтому это только факт «чистка прошла».
  final int cleanedRows;

  /// Не пусто — чистка Supabase не прошла (работа с Диском при этом успешна).
  final String? cleanupError;
  const AiChatExport({
    required this.chatId,
    required this.folder,
    required this.newMessages,
    required this.newMedia,
    required this.cleanedRows,
    this.cleanupError,
  });
}

/// Итог [ChatAiExport.exportAll].
class AiExportAll {
  final int chats;
  final int messages;
  final int media;
  final List<String> errors;

  /// Понятный пользователю текст: без ошибок — что сделано, с ошибками — первая из них.
  String messageText() {
    if (errors.isEmpty) {
      return tr('Выгружено сообщений: {n} (переписок: {m})', {'n': messages, 'm': chats});
    }
    return tr('Выгружено сообщений: {n}. Ошибки: {e}', {'n': messages, 'e': errors.first});
  }

  const AiExportAll({required this.chats, required this.messages, required this.media, required this.errors});
}

// ---------------------------------------------------------------------------
// Чистые функции формата — без сети и базы, покрыты test/chat_ai_export_test.dart
// ---------------------------------------------------------------------------

/// Корень выгрузок на Диске.
const aiExportRoot = 'Nexus/Chats';

/// kind в messages.jsonl: 'image' локальной базы называется 'photo'.
String aiMessageKind(String msgType) => switch (msgType) {
      'image' => 'photo',
      'text' || 'video' || 'audio' || 'file' || 'call' => msgType,
      _ => 'system',
    };

/// Строка messages.jsonl — один JSON-объект на строку. Порядок полей задан
/// здесь и проверяется тестами; экранирование берёт на себя jsonEncode.
String aiJsonLine({
  required String id,
  required String chat,
  String? from,
  required String to,
  required DateTime ts,
  required String kind,
  String? text,
  String? replyTo,
  Map<String, Object?>? file,
}) {
  return jsonEncode({
    'v': 1,
    'id': id,
    'chat': chat,
    if (from != null && from.isNotEmpty) 'from': from,
    'to': to,
    'ts': ts.toUtc().toIso8601String(),
    'kind': kind,
    if (text != null && text.isNotEmpty) 'text': text,
    if (replyTo != null && replyTo.isNotEmpty) 'reply_to': replyTo,
    if (file != null) 'file': file,
  });
}

/// Строка jsonl из модели локальной базы. [mediaPath] — путь вложения ВНУТРИ
/// папки переписки ('media/<файл>'); null — вложения на Диске нет.
/// Возвращает null для строк, годных только в chat.md, — когда нет и id.
String? aiJsonLineForMessage(
  ChatMessage m, {
  required String chatId,
  String? myId,
  bool isGroup = false,
  String? mediaPath,
}) {
  final outgoing = m.direction == ChatMessageDirection.outgoing;
  final from = outgoing
      ? (myId == null || myId.isEmpty ? 'me' : myId)
      : (m.senderId == null || m.senderId!.isEmpty ? chatId : m.senderId);
  final to = outgoing
      ? chatId
      : (isGroup || myId == null || myId.isEmpty ? chatId : myId);
  Map<String, Object?>? file;
  if (m.attachmentName != null && m.attachmentName!.isNotEmpty) {
    file = {
      'name': m.attachmentName,
      'mime': m.attachmentMime,
      'size': m.attachmentSize,
      'path': mediaPath,
    };
  }
  return aiJsonLine(
    id: messageKey(m),
    chat: chatId,
    from: from,
    to: to,
    ts: m.createdAt,
    kind: aiMessageKind(m.type.name),
    text: m.text,
    replyTo: m.replyToPreview,
    file: file,
  );
}

/// Ключ дедупликации сообщений (и он же `id` в jsonl) — client_message_id.
String messageKey(ChatMessage m) => m.clientMessageId;

/// id сообщений, уже выгруженных в messages.jsonl.
Set<String> aiExportedIds(String jsonlText) {
  final out = <String>{};
  for (final raw in const LineSplitter().convert(jsonlText)) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    try {
      final e = jsonDecode(t);
      if (e is Map) {
        final id = '${e['id']}';
        if (id.isNotEmpty && id != 'null') out.add(id);
      }
    } catch (_) {
      // битая строка не должна ронять разбор остальных
    }
  }
  return out;
}

/// Дописывает ТОЛЬКО новые строки: повторная выгрузка тех же id ничего
/// не добавляет; порядок входных строк сохраняется.
List<String> aiAppendLines(String existingJsonl, List<String> lines) {
  final known = aiExportedIds(existingJsonl);
  final out = <String>[];
  for (final line in lines) {
    var id = '';
    try {
      final e = jsonDecode(line);
      if (e is Map) id = '${e['id']}';
    } catch (_) {}
    if (id.isEmpty || id == 'null') {
      out.add(line); // не с чем свериться — пусть идёт
      continue;
    }
    if (known.add(id)) out.add(line);
  }
  return out;
}

/// Детерминированное имя вложения на Диске: то же сообщение всегда имеет то
/// же имя, поэтому «уже загружено» видно по одному списку папки media.
String aiAttachmentFileName(ChatMessage m) {
  final stamp = m.createdAt.toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
  return '${stamp.length > 14 ? stamp.substring(0, 14) : stamp}_${_safe(messageKey(m), max: 8)}_${_safe(m.attachmentName ?? 'file', max: 80)}';
}

/// Безопасная часть имени файла/папки.
String _safe(String s, {int max = 60}) {
  final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();
  return t.isEmpty ? 'chat' : (t.length > max ? t.substring(0, max) : t);
}

/// «ГГГГ-ММ-ДД ЧЧ:ММ» (UTC) — для chat.md.
String aiStamp(DateTime ts) {
  final u = ts.toUtc();
  final mm = u.month < 10 ? '0${u.month}' : '${u.month}';
  final dd = u.day < 10 ? '0${u.day}' : '${u.day}';
  final hh = u.hour < 10 ? '0${u.hour}' : '${u.hour}';
  final mi = u.minute < 10 ? '0${u.minute}' : '${u.minute}';
  return '${u.year}-$mm-$dd $hh:$mi';
}

/// В одну строку для chat.md: переводы строк мешают «одна запись — одна строка».
String _mdOneLine(String s) => s.replaceAll(RegExp(r'[\n\r]+'), ' ').trim();

/// Строка «[дата время] Имя: текст» для chat.md; для вложений — описание и путь.
String aiMdLine({
  required DateTime ts,
  required String name,
  required String kind,
  String? text,
  String? fileName,
  String? mediaPath,
}) {
  final cap = (text == null || text.isEmpty) ? '' : ' — ${_mdOneLine(text)}';
  final when = aiStamp(ts);
  final String body;
  switch (kind) {
    case 'photo':
      body = '📷 ${mediaPath ?? fileName ?? 'фото (файл не найден)'}$cap';
      break;
    case 'video':
      body = '🎥 ${mediaPath ?? fileName ?? 'видео (файл не найден)'}$cap';
      break;
    case 'audio':
      body = '🎤 ${mediaPath ?? fileName ?? 'голосовое (файл не найден)'}$cap';
      break;
    case 'file':
      body = '📎 ${mediaPath ?? fileName ?? 'файл (файл не найден)'}$cap';
      break;
    case 'call':
      body = '📞 Звонок$cap';
      break;
    case 'system':
      body = cap.isEmpty ? '' : cap.substring(3); // без " — "
      break;
    default:
      body = _mdOneLine(text ?? '');
  }
  return '[$when] $name: $body';
}

/// Шапка + строки chat.md (перегенерируется целиком при каждой выгрузке).
String aiChatMd({
  required String chatId,
  String? nickname,
  required bool isGroup,
  required List<String> members,
  required List<String> lines,
  required DateTime now,
}) {
  final title = isGroup ? 'Группа «${nickname ?? '—'}»' : 'Чат с ${nickname ?? '—'}';
  final mb = StringBuffer()
    ..writeln('# $title')
    ..writeln()
    ..writeln('- Переписка (id): $chatId')
    ..writeln('- Участники: ${members.isEmpty ? '—' : members.join(', ')}')
    ..writeln('- Сообщений: ${lines.length}')
    ..writeln('- Обновлено: ${aiStamp(now)} UTC')
    ..writeln('- Формат записей: [дата время UTC] Имя: текст; вложения показаны 📷/🎥/🎤/📎 со ссылкой на файл в media/')
    ..writeln('- Машиночитаемая версия: messages.jsonl (по одному объекту на строку)')
    ..writeln();
  for (final l in lines) {
    mb.writeln(l);
  }
  return mb.toString();
}

/// Памятка Nexus/Chats/AI-README.md — обновляется при каждой выгрузке.
String aiReadmeMd() => '''
# AI-README — как читать переписки в Nexus/Chats

Эта папка — единственное место, где хранится история переписок (Supabase используется
только для доставки новых сообщений и старое из него удаляется).

## Структура

- `Nexus/Chats/<chatId>/` — папка одной переписки (chatId — id собеседника или группы).
  - `messages.jsonl` — вся история: по одному JSON-объекту на строку, строки
    упорядочены по времени (ts), дописываются только новые (дубликатов id нет).
  - `chat.md` — та же история в человекочитаемом виде (маркдаун).
  - `media/` — сами фото, видео, аудио и файлы; имена файлов детерминированы,
    повторная выгрузка существующие не перезаливает.
- `Nexus/Chats/AI-README.md` — эта памятка.

## Поля messages.jsonl

- `v` — версия формата, сейчас `1`.
- `id` — строка-ключ сообщения (client_message_id); уникален в пределах переписки.
- `chat` — id переписки (совпадает с именем папки).
- `from` — id отправителя; для собственных исходящих сообщений — id автора приложения.
- `to` — id получателя (личный чат: собеседник или автор; группа: id группы).
- `ts` — время сообщения, ISO-8601 UTC (пример `2025-11-21T14:03:00.000Z`).
- `kind` — `text` | `photo` | `video` | `audio` | `file` | `call` | `system`.
- `text` — текст сообщения или подпись к вложению (может отсутствовать).
- `reply_to` — короткая цитата сообщения, на которое отвечали (может отсутствовать).
- `file` — для вложений: `name` (string), `mime` (string|null), `size` (int|null, байты),
  `path` — путь файла ВНУТРИ папки переписки, например `media/20251121140300_ab12_photo.jpg`;
  `path: null` — файла на Диске нет (слишком большой или не загружен).

## Как искать

- По тексту: grep/поиску подлежит `text` в `messages.jsonl` (jsonl устойчив к переносу строк:
  каждая запись — одна строка файла). Регистр букв ищите без учёта регистра.
- По времени: фильтруйте по полю `ts` лексикографически (`ts >= "2025-11-01"` работает,
  потому что ISO-8601 UTC сортируется как строка) или по диапазону дат в `chat.md`.
- По типу: фильтр `kind == "photo"` и т.п.

## Как открыть медиа

Путь к файлу — `file.path` внутри папки переписки: `<папка переписки>/media/<файл>`.
Если `file.path` равен null содержимое отсутствует — читайте только метаданные.

## Приватность

Файлы лежат в личной папке Google Диска владельца устройства. Это личная переписка:
не переносите её содержимое наружу без явного указания пользователя и не цитируйте
больше, чем нужно для ответа.
''';

// ---------------------------------------------------------------------------
// Сам экспорт
// ---------------------------------------------------------------------------

/// Выгрузка переписок на Google Диск в формате, удобном для ИИ:
/// `Nexus/Chats/<chatId>/messages.jsonl`, `chat.md`, `media/`.
///
/// Идемпотентность: сообщения дописываются по id из локальной базы (уже
/// выгруженные не дублируются), вложения не перезаливаются (то же имя файла
/// уже лежит в media/). При включённом режиме «только Диск» после успешной
/// выгрузки переписки старые строки её транзита удаляются из Supabase.
class ChatAiExport {
  static const _lastKey = 'chat_ai_export_last';
  static const _statusKey = 'chat_ai_export_status';
  static const _timeout = Duration(seconds: 60);

  static final _running = <String, Future<AiExportAll>>{};
  static bool get running => _running.isNotEmpty;

  final LocalDbService db;
  final ChatMessagesRepository repo;
  final GDriveService drive;
  final http.Client Function() clientFactory;

  ChatAiExport(LocalDbService db, GDriveService drive, {http.Client Function()? clientFactory})
      : this._(db, ChatMessagesRepository(db), drive, clientFactory: clientFactory);

  ChatAiExport._(this.db, this.repo, this.drive, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  /// Время последней выгрузки (null — ни разу).
  static DateTime? lastRun(LocalDbService db) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_lastKey]);
    return r.isEmpty ? null : DateTime.tryParse('${r.first['hex']}')?.toLocal();
  }

  /// Статус последней выгрузки: 'ok' или текст ошибки (для строки в настройках).
  static String? lastStatus(LocalDbService db) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_statusKey]);
    final v = r.isEmpty ? null : '${r.first['hex']}';
    return (v == null || v.isEmpty) ? null : v;
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, v]);

  /// Выгрузка ВСЕХ переписок. [onProgress] — (готово переписок, всего).
  /// Выгрузка уже идёт — исключение с понятным текстом (не молчание).
  Future<AiExportAll> exportAll({bool Function()? cancelled, void Function(int done, int total)? onProgress}) {
    if (_running.isNotEmpty) {
      throw AiExportException(tr('Выгрузка уже идёт, дождитесь её окончания'));
    }
    final f = _exportAll(cancelled: cancelled, onProgress: onProgress);
    _running['all'] = f;
    f.whenComplete(() => _running.remove('all'));
    return f;
  }

  Future<AiExportAll> _exportAll(
      {bool Function()? cancelled, void Function(int done, int total)? onProgress}) async {
    final contacts = repo.listContacts();
    var messages = 0;
    var media = 0;
    final errors = <String>[];
    var done = 0;
    onProgress?.call(0, contacts.length);
    for (final c in contacts) {
      if (cancelled?.call() == true) break;
      done++;
      try {
        final one = await exportChat(c.id);
        messages += one.newMessages;
        media += one.newMedia;
        if (one.cleanupError != null) errors.add(one.cleanupError!);
      } catch (e) {
        errors.add('${e is AiExportException ? '$e' : friendlyError(e)}');
      }
      onProgress?.call(done, contacts.length);
    }
    final ok = errors.isEmpty;
    _put(db, _lastKey, DateTime.now().toUtc().toIso8601String());
    _put(db, _statusKey, ok ? 'ok' : 'error: ${errors.take(2).join(' | ')}');
    return AiExportAll(chats: done, messages: messages, media: media, errors: errors);
  }

  /// Выгрузка одной переписки. Идемпотентна: добавляет только новые
  /// сообщения и только отсутствующие вложения, chat.md и AI-README.md
  /// перегенерируются.
  Future<AiChatExport> exportChat(String contactId) async {
    final contact = repo.contactById(contactId);
    final me = myId();
    final rows = db.db.select(
      'SELECT id, client_message_id, contact_id, direction, text, status, msg_type, '
      'NULL AS attachment_base64, attachment_name, attachment_mime, attachment_size, drive_file_id, attachment_local_path, '
      'reply_to_client_message_id, reply_to_preview, seen, download_allowed, call_status, sender_id, peer_read, created_at '
      'FROM chat_local_messages WHERE contact_id = ? ORDER BY created_at',
      [contactId],
    );
    final messages = [for (final r in rows) ChatMessage.fromRow(r)];

    final root = await drive.ensurePath(aiExportRoot);
    final dirId = await drive.ensurePath('$aiExportRoot/$contactId');
    final mediaDirId = await drive.ensurePath('$aiExportRoot/$contactId/media');

    final listing = await drive.list(dirId);
    final idx = listing.files.where((f) => f.name == 'messages.jsonl').firstOrNull;
    var existing = '';
    if (idx != null) {
      try {
        existing = utf8.decode((await drive.get(idx.id)).bytes, allowMalformed: true);
      } catch (e) {
        throw AiExportException('${tr('messages.jsonl на Диске не читается')}: $e');
      }
    }
    final known = aiExportedIds(existing);
    final mediaNames = <String>{for (final f in (await drive.list(mediaDirId)).files) f.name};

    // 1. Вложения: не перезаливаем те, что уже в media/ (имя детерминировано).
    var newMedia = 0;
    final mediaPaths = <String, String>{}; // messageKey -> 'media/<имя>'
    for (final m in messages) {
      if (m.attachmentName == null || m.attachmentName!.isEmpty) continue;
      final fileName = aiAttachmentFileName(m);
      if (mediaNames.contains(fileName)) {
        mediaPaths[messageKey(m)] = 'media/$fileName';
        continue;
      }
      final bytes = await _mediaBytes(m);
      if (bytes == null) continue; // нечего грузить (слишком большое/файла нет)
      try {
        await drive.put(mediaDirId, fileName, m.attachmentMime ?? 'application/octet-stream', bytes);
      } catch (e) {
        throw AiExportException('${tr('Вложение «{n}» не загружено', {'n': m.attachmentName})}: $e');
      }
      mediaNames.add(fileName);
      mediaPaths[messageKey(m)] = 'media/$fileName';
      newMedia++;
    }

    // 2. messages.jsonl: дописываем только новые id.
    final newLines = [
      for (final m in messages)
        if (messageKey(m).isNotEmpty && !known.contains(messageKey(m)))
          aiJsonLineForMessage(
            m,
            chatId: contactId,
            myId: me,
            isGroup: contact?.isGroup ?? false,
            mediaPath: mediaPaths[messageKey(m)],
          )!,
    ];
    if (newLines.isNotEmpty) {
      final sb = StringBuffer(existing);
      if (existing.isNotEmpty && !existing.endsWith('\n')) sb.writeln();
      sb.write(newLines.join('\n'));
      sb.writeln();
      await drive.put(dirId, 'messages.jsonl', 'text/plain', utf8.encode(sb.toString()), overwriteId: idx?.id);
    }

    // 3. chat.md — человекочитаемая версия, перегенерируется целиком.
    final mdLines = [
      for (final m in messages)
        aiMdLine(
          ts: m.createdAt,
          name: _displayName(m, contact, me),
          kind: aiMessageKind(m.type.name),
          text: m.text,
          fileName: m.attachmentName,
          mediaPath: mediaPaths[messageKey(m)],
        ),
    ];
    final members = [
      for (final mem in contact?.members ?? const <ChatGroupMember>[]) mem.nickname
    ];
    final mdFile = listing.files.where((f) => f.name == 'chat.md').firstOrNull;
    await drive.put(
      dirId,
      'chat.md',
      'text/markdown',
      utf8.encode(aiChatMd(
        chatId: contactId,
        nickname: contact?.nickname,
        isGroup: contact?.isGroup ?? false,
        members: members,
        lines: mdLines,
        now: DateTime.now(),
      )),
      overwriteId: mdFile?.id,
    );

    // 4. Памятка для ИИ — в корне, обновляется при каждой выгрузке.
    await _writeReadme(root);

    // 5. Режим «только Диск»: чистим старый транзит этой переписки в Supabase.
    var cleaned = 0;
    String? cleanupError;
    if (ChatDriveBackup.driveOnlyOn(db)) {
      try {
        await cleanupSupabaseTransit(contactId, isGroup: contact?.isGroup ?? false);
        cleaned = 1;
      } catch (e) {
        // Данные не потеряны: они на Диске и в локальной базе; но сообщаем ясно.
        cleanupError =
            '${contact?.nickname ?? contactId}: ${tr('не удалось удалить старые сообщения из Supabase')}: $e';
      }
    }
    return AiChatExport(
      chatId: contactId,
      folder: '$aiExportRoot/$contactId',
      newMessages: newLines.length,
      newMedia: newMedia,
      cleanedRows: cleaned,
      cleanupError: cleanupError,
    );
  }

  /// Идентификатор автора приложения в общем чате (для from/to).
  String myId() => ChatAuthService(db).userId;

  /// Тело вложения: blob из локальной базы или файл по локальному пути (не веб).
  Future<List<int>?> _mediaBytes(ChatMessage m) async {
    if (m.attachmentSize != null && m.attachmentSize! > ChatDriveBackup.maxFileBytes) return null;
    if (m.attachmentBase64 != null) {
      final b = db.db.select('SELECT attachment_base64 AS b FROM chat_local_messages WHERE id = ?', [m.id]);
      final s = b.isEmpty ? null : b.first['b'] as String?;
      if (s == null || s.isEmpty) return null;
      try {
        return base64Decode(s);
      } catch (_) {
        return null;
      }
    }
    if (!kIsWeb && m.attachmentLocalPath != null && m.attachmentLocalPath!.isNotEmpty) {
      return readLocalBytes(m.attachmentLocalPath!, maxBytes: ChatDriveBackup.maxFileBytes);
    }
    return null;
  }

  String _displayName(ChatMessage m, ChatContact? contact, String me) {
    if (m.direction == ChatMessageDirection.outgoing) return 'Я';
    final sid = m.senderId ?? '';
    if (sid.isNotEmpty && me.isNotEmpty && sid == me) return 'Я';
    if (contact != null && contact.isGroup && sid.isNotEmpty) {
      for (final mem in contact.members) {
        if (mem.id == sid) return mem.nickname;
      }
      return sid; // участника не найти — покажем id
    }
    final nick = contact?.nickname ?? '';
    return nick.isEmpty ? 'Собеседник' : nick;
  }

  /// Пишет/обновляет Nexus/Chats/AI-README.md.
  Future<void> _writeReadme(String rootId) async {
    final l = await drive.list(rootId);
    final f = l.files.where((x) => x.name == 'AI-README.md').firstOrNull;
    await drive.put(rootId, 'AI-README.md', 'text/markdown', utf8.encode(aiReadmeMd()),
        overwriteId: f?.id);
  }

  // ---- Чистка транзита в Supabase (режим «только Диск») ----

  /// URL чистки (чистая функция — тестируется без сети). RLS базы разрешает
  /// удалять только свои строки (sender_id = я или recipient_id = я, см.
  /// `chat_messages_delete` в sql/chat-schema.sql), чужие PostgREST не отдаст.
  static String transitCleanupUrl(
    String base, {
    required String me,
    required String chatId,
    required bool isGroup,
    required String cutoffUtcIso,
  }) {
    // PostgREST: `or=(...)` — скобки ровно одни; у личного чата внутри уже
    // два `and(...)`, у группы — один простой фильтр.
    final scope = isGroup
        ? '(group_id.eq.$chatId)'
        : '(and(sender_id.eq.$me,recipient_id.eq.$chatId),and(sender_id.eq.$chatId,recipient_id.eq.$me))';
    return '${base.replaceAll(RegExp(r'/+$'), '')}'
        '/rest/v1/chat_messages?created_at=lt.${Uri.encodeComponent(cutoffUtcIso)}&or=$scope';
  }

  /// Удаляет из chat_messages строки этой переписки старше [daysOld] дней.
  /// Возвращает true, если просьба дошла до сервера (код 2xx).
  Future<bool> cleanupSupabaseTransit(String chatId, {bool isGroup = false, int daysOld = 7}) async {
    if (!ChatSettings.isConfigured || !ChatSettings.url.startsWith('https://')) {
      throw AiExportException(tr('Сервер общего чата не настроен'));
    }
    final auth = ChatAuthService(db);
    final me = auth.userId;
    if (me.isEmpty) throw AiExportException(tr('Нет учётной записи общего чата — войдите в мессенджер'));
    final token = await auth.ensureFreshToken();
    if (token == null) throw AiExportException(tr('Не удалось войти в общий чат — истёк доступ'));
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: daysOld));
    final client = clientFactory();
    try {
      final res = await client
          .delete(
            Uri.parse(transitCleanupUrl(
              ChatSettings.url,
              me: me,
              chatId: chatId,
              isGroup: isGroup,
              cutoffUtcIso: cutoff.toIso8601String(),
            )),
            headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode >= 400) {
        throw AiExportException('${tr('Supabase ответил кодом {s}', {'s': res.statusCode})}: ${utf8.decode(res.bodyBytes)}');
      }
      // 204 без тела — число удалённого PostgREST наружу не отдаёт.
      return true;
    } finally {
      client.close();
    }
  }
}
