// Формат экспорта переписок на Диск «для ИИ» (ChatAiExport) — без сети:
// чистые функции формата и идемпотентность на эмуляторе моста Apps Script.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/gdrive/chat_ai_export.dart';
import 'package:shooting_app/gdrive/gdrive_service.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';

ChatMessage _m({
  String id = 'c1',
  String chat = 'peer1',
  ChatMessageDirection dir = ChatMessageDirection.outgoing,
  ChatMessageType type = ChatMessageType.text,
  String? text = 'Привет',
  String? name,
  String? mime,
  int? size,
  String? senderId,
  DateTime? at,
}) =>
    ChatMessage(
      id: id,
      clientMessageId: id,
      contactId: chat,
      direction: dir,
      status: ChatMessageStatus.delivered,
      type: type,
      text: text,
      attachmentName: name,
      attachmentMime: mime,
      attachmentSize: size,
      senderId: senderId,
      createdAt: at ?? DateTime.utc(2025, 11, 21, 14, 3),
    );

void main() {
  test('jsonl: поля в заданном порядке, время — ISO UTC, экранирование', () {
    final line = aiJsonLineForMessage(_m(text: 'Многострочный\n"текст" и \\ слэш'), chatId: 'peer1', myId: 'me')!;
    expect(line.contains('\n'), isFalse); // одна запись — одна строка файла
    final e = jsonDecode(line) as Map<String, dynamic>;
    expect(e.keys.toList(), ['v', 'id', 'chat', 'from', 'to', 'ts', 'kind', 'text']);
    expect(e['v'], 1);
    expect(e['id'], 'c1');
    expect(e['chat'], 'peer1');
    expect(e['from'], 'me');
    expect(e['to'], 'peer1');
    expect(e['ts'], '2025-11-21T14:03:00.000Z');
    expect(e['kind'], 'text');
    expect(e['text'], 'Многострочный\n"текст" и \\ слэш');
    expect(e.containsKey('reply_to'), isFalse);
  });

  test('jsonl: вложение даёт блок file с именем, mime, размером и путём', () {
    final line = aiJsonLineForMessage(
      _m(text: 'снимок', type: ChatMessageType.image, name: 'фото.png', mime: 'image/png', size: 12345),
      chatId: 'peer1',
      myId: 'me',
      mediaPath: 'media/20251121140300_c1_фото.png',
    )!;
    final e = jsonDecode(line) as Map<String, dynamic>;
    expect(e['kind'], 'photo'); // локальный 'image' в файле называется 'photo'
    final f = e['file'] as Map<String, dynamic>;
    expect(f['name'], 'фото.png');
    expect(f['mime'], 'image/png');
    expect(f['size'], 12345);
    expect(f['path'], 'media/20251121140300_c1_фото.png');
  });

  test('jsonl: входящее в группу — from это автор, to — группа; reply_to попадает', () {
    final line = aiJsonLineForMessage(
      _m(dir: ChatMessageDirection.incoming, type: ChatMessageType.file, name: 'отчёт.pdf', senderId: 'u2',
          text: 'см. отчёт'),
      chatId: 'g1',
      isGroup: true,
      mediaPath: 'media/f.pdf',
    )!;
    final e = jsonDecode(line) as Map<String, dynamic>;
    expect(e['from'], 'u2');
    expect(e['to'], 'g1');
    expect(e['kind'], 'file');
    expect(e['text'], 'см. отчёт');
  });

  test('kind: локальные msg_type переводятся в названия формата', () {
    expect(aiMessageKind('image'), 'photo');
    expect(aiMessageKind('text'), 'text');
    expect(aiMessageKind('video'), 'video');
    expect(aiMessageKind('audio'), 'audio');
    expect(aiMessageKind('file'), 'file');
    expect(aiMessageKind('call'), 'call');
    expect(aiMessageKind('edit'), 'system'); // служебные сигналы — system
  });

  test('дедупликация по id: повторная выгрузка не пишет те же строки', () {
    final l1 = aiJsonLineForMessage(_m(id: 'c1'), chatId: 'peer1')!;
    final l2 = aiJsonLineForMessage(_m(id: 'c2', text: 'второе'), chatId: 'peer1')!;
    final l3 = aiJsonLineForMessage(_m(id: 'c3', text: 'третье'), chatId: 'peer1')!;
    expect(aiExportedIds('$l1\n$l2\n'), {'c1', 'c2'});
    // l1 уже есть, l2 дублируется в самой пачке — новые только l3
    final added = aiAppendLines('$l1\n$l2\n', [l1, l2, l2, l3]);
    expect(added, [l3]);
    // битая строка не мешает разбору
    expect(aiExportedIds('это не json\n$l1\n'), {'c1'});
    expect(aiAppendLines('', ['мусор без json', l2, l2]), ['мусор без json', l2]);
  });

  test('имя вложения детерминировано и переиспользуется между выгрузками', () {
    final a = _m(id: 'cm-1', type: ChatMessageType.image, name: 'фото.png', mime: 'image/png');
    expect(aiAttachmentFileName(a), aiAttachmentFileName(a.copyWith()));
    expect(aiAttachmentFileName(a), isNot(contains('/')));
    expect(aiAttachmentFileName(a), isNot(contains(':')));
    final b = _m(id: 'cm-2', type: ChatMessageType.image, name: 'фото.png', mime: 'image/png');
    expect(aiAttachmentFileName(b), isNot(aiAttachmentFileName(a)));
  });

  test('chat.md: заголовок, участники, «[дата время] Имя: текст», ссылка на медиа', () {
    final l1 = aiMdLine(ts: _m().createdAt, name: 'Мария', kind: 'text', text: 'Строка\nвторая');
    expect(l1, '[2025-11-21 14:03] Мария: Строка вторая');
    final l2 = aiMdLine(ts: _m().createdAt, name: 'Я', kind: 'file', text: 'смотри',
        fileName: 'отчёт.pdf', mediaPath: 'media/20251121140300_c2_отчёт.pdf');
    expect(l2, contains('📎 media/20251121140300_c2_отчёт.pdf — смотри'));
    final md = aiChatMd(
      chatId: 'peer1',
      nickname: 'Мария',
      isGroup: false,
      members: const ['Мария'],
      lines: [l1, l2],
      now: DateTime.utc(2025, 11, 25, 10, 0),
    );
    expect(md, contains('# Чат с Мария'));
    expect(md, contains('- Переписка (id): peer1'));
    expect(md, contains('- Участники: Мария'));
    expect(md, contains('- Сообщений: 2'));
    expect(md.contains(l1) && md.contains(l2), isTrue);
  });

  test('README-памятка описывает поля, поиск и приватность', () {
    final md = aiReadmeMd();
    expect(md, contains('Nexus/Chats/<chatId>/'));
    expect(md, contains('messages.jsonl'));
    expect(md, contains('chat.md'));
    expect(md, contains('media/'));
    expect(md, contains('`ts`'));
    expect(md, contains('`kind`'));
    expect(md, contains('path'));
    expect(md, contains('grep'));
    expect(md.toLowerCase(), contains('приватность'));
  });

  test('URL чистки транзита: личный чат — пара участников, группа — group_id', () {
    final personal = ChatAiExport.transitCleanupUrl(
      'https://chat.example.com/',
      me: 'me',
      chatId: 'peer1',
      isGroup: false,
      cutoffUtcIso: '2025-11-25T10:00:00.000Z',
    );
    expect(Uri.parse(personal).path, '/rest/v1/chat_messages');
    expect(personal, contains('created_at=lt.2025-11-25T10%3A00%3A00.000Z'));
    expect(personal, contains('or=(and(sender_id.eq.me,recipient_id.eq.peer1),'
        'and(sender_id.eq.peer1,recipient_id.eq.me))'));
    final group = ChatAiExport.transitCleanupUrl(
      'https://chat.example.com/',
      me: 'me',
      chatId: 'g1',
      isGroup: true,
      cutoffUtcIso: '2025-11-25T10:00:00.000Z',
    );
    // Группа: один простой фильтр внутри or=, без лишней обёртки.
    expect(group, contains('&or=(group_id.eq.g1)'));
  });
}

// ---------------------------------------------------------------------------
// Эмулятор моста Apps Script (docs/gdrive-script.gs) — проверить идемпотентность
// exportChat без сети: вторая выгрузка не пишет ни сообщений, ни медиа.
// ---------------------------------------------------------------------------

class _Bridge {
  final paths = <String, String>{}; // 'Nexus/Chats/peer1' -> id папки
  final folders = <String, Map<String, String>>{}; // id -> {name, parent}
  final files = <String, Map<String, dynamic>>{}; // id -> {name, mime, parent}
  final bytesOf = <String, List<int>>{};
  int mediaUploads = 0; // загрузки вложений (mime image/)
  var _seq = 0;

  String _next() => 'id${++_seq}';

  http.Response _resp(Object data) =>
      http.Response(jsonEncode({'ok': true, 'data': data}), 200, headers: {'content-type': 'application/json'});

  String _folderId(String parent, String name) {
    final existing = folders.entries.where((e) => e.value['parent'] == parent && e.value['name'] == name);
    if (existing.isNotEmpty) return existing.first.key;
    final id = _next();
    folders[id] = {'name': name, 'parent': parent};
    return id;
  }

  Map<String, dynamic> _item(String id, Map<String, dynamic> meta) => {
        'id': id,
        'name': meta['name'],
        'mime': meta['mime'],
        'size': bytesOf[id]?.length ?? 0,
        'modified': 0,
        'url': 'u',
        'isFolder': false,
      };

  Map<String, dynamic> _listing(String folderId) {
    final name = folderId == 'root' ? 'Мой диск' : folders[folderId]!['name'];
    return {
      'id': folderId,
      'name': name,
      'stamp': 0,
      'parent': folderId == 'root' ? null : folders[folderId]!['parent'],
      'folders': [
        for (final e in folders.entries)
          if (e.value['parent'] == folderId)
            {'id': e.key, 'name': e.value['name'], 'mime': 'folder', 'size': 0, 'modified': 0, 'url': 'u', 'isFolder': true},
      ],
      'files': [
        for (final e in files.entries)
          if (e.value['parent'] == folderId) _item(e.key, e.value),
      ],
    };
  }

  Future<http.Response> handler(http.Request req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    switch (body['action'] as String) {
      case 'ensurePath':
        var parent = 'root';
        var cur = '';
        for (final part in (body['path'] as String).split('/')) {
          cur = cur.isEmpty ? part : '$cur/$part';
          paths[cur] = _folderId(parent, part);
          parent = paths[cur]!;
        }
        return _resp({'id': parent});
      case 'list':
        return _resp(_listing(body['folderId'] as String));
      case 'put':
        final parentId = body['parentId'] as String;
        final name = body['name'] as String;
        final overwriteId = body['overwriteId'] as String?;
        final bytes = base64Decode(body['b64'] as String);
        String id;
        if (overwriteId != null && files.containsKey(overwriteId)) {
          id = overwriteId;
          bytesOf[id] = bytes;
        } else {
          id = _next();
          files[id] = {'name': name, 'mime': body['mime'], 'parent': parentId};
          bytesOf[id] = bytes;
          if (body['mime'] == 'image/png') mediaUploads++;
        }
        return _resp(_item(id, files[id]!));
      case 'get':
        final id = body['id'] as String;
        final f = files[id]!;
        return _resp({'name': f['name'], 'mime': f['mime'], 'b64': base64Encode(bytesOf[id]!), 'url': 'u'});
      default:
        return http.Response(jsonEncode({'ok': false, 'error': 'unknown action'}), 200);
    }
  }

  /// Текст файла по пути на Диске.
  String findText(String folderId, String name) {
    final e = files.entries.where((e) => e.value['parent'] == folderId && e.value['name'] == name).single;
    return utf8.decode(bytesOf[e.key]!);
  }

  String idByPath(String path) => paths[path]!;
}

Future<LocalDbService> _dbWithHistory() async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  GDriveService.save(db, url: 'https://script.google.com/macros/s/X/exec', secret: 'pass');
  final repo = ChatMessagesRepository(db);
  repo.addContact(ChatContact(id: 'peer1', nickname: 'Мария', chatCode: '', addedAt: DateTime.now()));
  repo.addMessage(_m(id: 'c1', text: 'первое', at: DateTime.utc(2025, 11, 21, 10, 0)));
  repo.addMessage(_m(
    id: 'c2',
    text: 'снимок',
    type: ChatMessageType.image,
    name: 'фото.png',
    mime: 'image/png',
    size: 3,
    at: DateTime.utc(2025, 11, 21, 10, 1),
  ));
  db.db.execute('UPDATE chat_local_messages SET attachment_base64 = ? WHERE id = ?', [base64Encode([1, 2, 3]), 'c2']);
  repo.addMessage(_m(id: 'c3', text: 'третье', at: DateTime.utc(2025, 11, 21, 10, 2)));
  return db;
}

/// Экспорт в Drive-эмулятор (см. _Bridge ниже).
void driveExportTests() {
  test('exportChat: вторая выгрузка не дублирует сообщения и не перезаливает медиа', () async {
    final db = await _dbWithHistory();
    final bridge = _Bridge();
    final drive = GDriveService(db, clientFactory: () => MockClient(bridge.handler));
    final svc = ChatAiExport(db, drive);

    final first = await svc.exportChat('peer1');
    expect(first.newMessages, 3);
    expect(first.newMedia, 1);
    expect(bridge.mediaUploads, 1);

    final chatDir = bridge.idByPath('Nexus/Chats/peer1');
    final jsonl = bridge.findText(chatDir, 'messages.jsonl');
    final ids = aiExportedIds(jsonl);
    expect(ids, {'c1', 'c2', 'c3'});
    final lines = jsonl.trim().split('\n');
    expect(lines.length, 3);
    // порядок по времени и поля вложения со ссылкой на media/
    expect(lines[0], contains('первое'));
    final f = (jsonDecode(lines[1]) as Map)['file'] as Map;
    expect(f['path'], startsWith('media/'));
    // chat.md и памятка на месте
    expect(bridge.findText(chatDir, 'chat.md'), contains('# Чат с Мария'));
    expect(bridge.findText(bridge.idByPath('Nexus/Chats'), 'AI-README.md'), contains('AI-README'));

    final second = await svc.exportChat('peer1');
    expect(second.newMessages, 0);
    expect(second.newMedia, 0);
    expect(bridge.mediaUploads, 1); // вложение не перезаливалось
    // jsonl не задублировался
    expect(aiExportedIds(bridge.findText(chatDir, 'messages.jsonl')), {'c1', 'c2', 'c3'});
    expect(bridge.findText(chatDir, 'messages.jsonl').trim().split('\n').length, 3);
  });
}
