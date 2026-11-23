import 'app_lock.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;
import 'package:uuid/uuid.dart';

import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import 'chat_messages_repository.dart';
import 'kdf.dart';
import 'local_db_service.dart';

/// Шифратор AES-256-GCM для ключа папки (ключ уже получен из пароля, см. Kdf).
enc.Encrypter _crypter(Uint8List key) => enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));

/// Один блок: IV (12 байт) + шифртекст с тегом.
Uint8List _sealWith(enc.Encrypter crypter, List<int> plain) {
  final iv = enc.IV.fromSecureRandom(12);
  final out = crypter.encryptBytes(plain, iv: iv);
  return Uint8List.fromList([...iv.bytes, ...out.bytes]);
}

/// Обратное к [_sealWith]. Исключение — блок испорчен или ключ чужой.
Uint8List _openWith(enc.Encrypter crypter, List<int> data) {
  final raw = data is Uint8List ? data : Uint8List.fromList(data);
  final out = crypter.decryptBytes(enc.Encrypted(Uint8List.sublistView(raw, 12)), iv: enc.IV(Uint8List.sublistView(raw, 0, 12)));
  return Uint8List.fromList(out);
}

// ---- Тяжёлая работа в отдельном изоляте -------------------------------------
// AES-GCM, base64 и JSON на тысячах сообщений замораживали главный изолят —
// отсюда «приложение не отвечает» при входе в мессенджер (отзыв 22.11).
// Функции верхнего уровня: изоляту нужна точка входа, а не замыкание.

/// Пачка записей индекса: `[ключ, [utf8(json)…]]` → зашифрованные блоки.
List<Uint8List> _sealManyIsolate(List<Object> args) {
  final crypter = _crypter(args[0] as Uint8List);
  final plains = args[1] as List<List<int>>;
  return [for (final plain in plains) _sealWith(crypter, plain)];
}

/// Пачка записей индекса: `[ключ, [блок…]]` → `[json…]`, пустая строка — битая.
List<String> _openManyIsolate(List<Object> args) {
  final crypter = _crypter(args[0] as Uint8List);
  final blobs = args[1] as List<Uint8List>;
  final out = <String>[];
  for (final b in blobs) {
    try {
      out.add(utf8.decode(_openWith(crypter, b)));
    } catch (_) {
      out.add('');
    }
  }
  return out;
}

/// Один зашифрованный блок (файл вложения): `[ключ, блок]` → байты.
Uint8List _openOneIsolate(List<Object> args) => _openWith(_crypter(args[0] as Uint8List), args[1] as List<int>);

/// Один файл вложения на запись: `[ключ, байты]` → зашифрованный блок.
Uint8List _sealOneIsolate(List<Object> args) => _sealWith(_crypter(args[0] as Uint8List), args[1] as List<int>);

Uint8List _base64DecodeIsolate(String s) => base64Decode(s);

/// Запись индекса, ждущая переноса в приложение: откуда читать и что в записи.
class _VaultItem {
  final String dirPath;
  final String contactId;
  final Map<String, dynamic> entry;
  final bool encrypted;
  const _VaultItem(this.dirPath, this.contactId, this.entry, {required this.encrypted});
}

/// Папка `Nexus/Chats` в общей памяти телефона: файлы переписок и их история, ЗАШИФРОВАННЫЕ
/// паролем пользователя. Удаление приложения её не трогает; после переустановки пароль вводится
/// снова и «Восстановить» возвращает сообщения с вложениями. Нужен доступ ко всем файлам
/// (включает сам пользователь в настройках Android).
///
/// Защита: ключ AES-256 получается из пароля (PBKDF2-HMAC-SHA256, соль в `vault.json`), каждый
/// файл шифруется AES-GCM со своим вектором. Имена собеседников и вложений в открытом виде не
/// хранятся (папки — по хешу, названия внутри зашифрованного индекса). Забытый пароль не
/// восстановить: без него данные не открыть никому.
///
/// Раскладка: `Nexus/Chats/vault.json`, `<хеш>/contact.enc`, `<хеш>/index.enc` (записи
/// «длина + зашифрованный JSON») и вложения `<имя>.bin`.
class ChatVault {
  static const _onKey = 'chat_vault_on';
  static const _cursorKey = 'chat_vault_cursor';
  static const _keyName = 'nexus_vault_key_v1';
  static const _checkText = 'nexus-vault-ok';
  static const _iterations = 60000;
  static const _maxRestoreInline = 8 * 1024 * 1024; // крупнее — не грузим в память, открываем с диска
  static const _batch = 50; // сообщений/файлов за один заход: между пачками отдаём кадр
  static const _isolateMinBytes = 512 * 1024; // с этого размера base64-разбор — в изоляте
  static final _root = Directory('/storage/emulated/0/Nexus/Chats');
  static File get _vaultFile => File(p.join(_root.path, 'vault.json'));

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
    final r = await AppLock.external(() => Permission.manageExternalStorage.request());
    if (r.isGranted) return true;
    return (await AppLock.external(() => Permission.storage.request())).isGranted;
  }

  static Future<bool> exists() async {
    try {
      return supported && await _root.exists() && (await _root.list().isEmpty) == false;
    } catch (_) {
      return false;
    }
  }

  // ---------------- ключ ----------------

  static Uint8List? _key;

  /// Ключ уже есть на этом телефоне (пароль вводили).
  static Future<bool> hasKey() async => (await _loadKey()) != null;

  static Future<Uint8List?> _loadKey() async {
    if (_key != null) return _key;
    try {
      final v = await const FlutterSecureStorage().read(key: _keyName);
      if (v != null && v.isNotEmpty) _key = base64Decode(v);
    } catch (_) {}
    return _key;
  }

  /// В папке уже есть зашифрованное хранилище (после переустановки: пароль нужен прежний).
  static Future<bool> hasVaultFile() async {
    try {
      return supported && await _vaultFile.exists();
    } catch (_) {
      return false;
    }
  }

  static Uint8List _sealBytes(Uint8List key, List<int> plain) => _sealWith(_crypter(key), plain);

  static Uint8List _openBytes(Uint8List key, List<int> data) => _openWith(_crypter(key), data);

  /// Первый раз: создаёт хранилище с этим паролем. Хранилище уже есть: проверяет пароль по нему.
  /// Верный пароль — ключ запоминается в защищённом хранилище телефона (для фоновой работы).
  /// `false` — пароль неверный.
  static Future<bool> setPassword(String password) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    await _root.create(recursive: true);
    Uint8List key;
    if (await _vaultFile.exists()) {
      final meta = jsonDecode(await _vaultFile.readAsString()) as Map<String, dynamic>;
      key = await Kdf.derive(password, base64Decode('${meta['salt']}'), iterations: (meta['iter'] as num?)?.toInt() ?? _iterations);
      try {
        if (utf8.decode(_openBytes(key, base64Decode('${meta['check']}'))) != _checkText) return false;
      } catch (_) {
        return false;
      }
    } else {
      final salt = Kdf.randomBytes(16);
      key = await Kdf.derive(password, salt, iterations: _iterations);
      await _vaultFile.writeAsString(jsonEncode({
        'v': 2,
        'salt': base64Encode(salt),
        'iter': _iterations,
        'check': base64Encode(_sealBytes(key, utf8.encode(_checkText))),
      }));
    }
    _key = key;
    await const FlutterSecureStorage().write(key: _keyName, value: base64Encode(key));
    return true;
  }

  @visibleForTesting
  static Uint8List sealForTest(Uint8List key, List<int> plain) => _sealBytes(key, plain);
  @visibleForTesting
  static Uint8List openForTest(Uint8List key, List<int> data) => _openBytes(key, data);
  @visibleForTesting
  static List<Map<String, dynamic>> readRecordsForTest(Uint8List key, Uint8List data) => _readRecords(key, data);

  static String _folderOf(Uint8List key, String contactId) {
    final d = SHA256Digest().process(Uint8List.fromList([...key, ...utf8.encode(contactId)]));
    return 'c_${d.sublist(0, 12).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String _safe(String s, {int max = 40}) {
    final t = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return t.isEmpty ? 'x' : (t.length > max ? t.substring(0, max) : t);
  }

  static Future<void> syncIfOn(LocalDbService db, {Duration budget = const Duration(seconds: 8)}) async {
    if (!isOn(db)) return;
    try {
      if (!(await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted)) return;
      if (await _loadKey() == null) return; // пароль ещё не задан
      // Вход в мессенджер не должен ждать всю папку: проход ограничен по времени,
      // остаток допишется при следующем открытии (отзыв 22.11 — «приложение не
      // отвечает» при каждом входе, когда папка включена на большой истории).
      await sync(db, budget: budget);
    } catch (_) {}
  }

  /// Один проход выкладки за раз: фоновый `syncIfOn` при входе и ручное
  /// «Сохранить сейчас» могли идти одновременно и дописать одни и те же записи
  /// в индекс дважды (отзыв 22.11).
  static Future<int>? _syncing;

  /// Дописывает в папку всё новое с прошлого раза (по порядку записи сообщений на
  /// телефоне). Возвращает число сохранённых сообщений.
  ///
  /// Работа идёт пачками по [_batch]: AES-GCM пачки записей и крупный base64 — в
  /// отдельном изоляте, между пачками отдаём кадр (`Future.delayed(zero)`), чтобы
  /// интерфейс не замирал (отзыв 22.11: «приложение не отвечает» после включения
  /// защищённой папки). [onProgress] — (сохранено, всего), [cancelled] — кнопка
  /// «Отмена» на экране, [budget] — предел времени прохода (фон при входе):
  /// остаток откладывается до следующего раза.
  static Future<int> sync(LocalDbService db,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled, Duration? budget}) async {
    final running = _syncing;
    if (running != null) {
      // Уже идёт проход (фон при входе): дожидаемся его и делаем свой — со своим
      // прогрессом и отменой, а не подсовываем чужой. Дублирования нет: курсор
      // уже сдвинут.
      try {
        await running;
      } catch (_) {}
      if (identical(_syncing, running)) _syncing = null;
    }
    final f = _syncImpl(db, onProgress: onProgress, cancelled: cancelled, budget: budget);
    _syncing = f;
    // Отметку снимаем в любом исходе; ошибку гасим здесь — её ждёт вызывающий.
    f.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_syncing, f)) _syncing = null;
    });
    return f;
  }

  static Future<int> _syncImpl(LocalDbService db,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled, Duration? budget}) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    final key = await _loadKey();
    if (key == null) throw StateError('не задан пароль папки');
    final started = DateTime.now();
    var cursor = int.tryParse(_get(db, _cursorKey) ?? '') ?? 0;
    final pending = db.db.select('SELECT COUNT(*) AS n FROM chat_local_messages WHERE rowid > ?', [cursor]).first['n'] as int;
    onProgress?.call(0, pending);
    var total = 0;
    while (true) {
      if (cancelled?.call() == true) break;
      final rows = db.db.select(
        'SELECT m.rowid AS rid, m.id, m.client_message_id, m.contact_id, c.nickname, m.direction, m.msg_type, m.text, '
        'm.reply_to_preview, m.attachment_name, m.attachment_mime, m.attachment_size, m.attachment_local_path, '
        '(m.attachment_base64 IS NOT NULL) AS has_blob, m.sender_id, m.created_at '
        'FROM chat_local_messages m LEFT JOIN chat_contacts c ON c.id = m.contact_id '
        'WHERE m.rowid > ? ORDER BY m.rowid LIMIT $_batch',
        [cursor],
      );
      if (rows.isEmpty) break;
      final entries = <Map<String, dynamic>>[];
      final dirs = <String>[];
      for (final r in rows) {
        final dir = Directory(p.join(_root.path, _folderOf(key, '${r['contact_id']}')));
        await dir.create(recursive: true);
        final meta = File(p.join(dir.path, 'contact.enc'));
        if (!await meta.exists()) {
          // Метаданные контакта — пара сотен байт, изолят дороже самой работы.
          await meta.writeAsBytes(_sealBytes(key, utf8.encode(jsonEncode({'id': r['contact_id'], 'nickname': r['nickname']}))));
        }
        String? file;
        final name = r['attachment_name'] as String?;
        if (name != null && (r['has_blob'] == 1 || r['attachment_local_path'] != null)) {
          final stamp = '${r['created_at']}'.replaceAll(RegExp(r'[^0-9]'), '');
          final fileName = '${stamp.length > 14 ? stamp.substring(0, 14) : stamp}_${_safe('${r['id']}', max: 8)}.bin';
          final target = File(p.join(dir.path, fileName));
          if (!await target.exists()) {
            Uint8List? bytes;
            if (r['has_blob'] == 1) {
              final b = db.db.select('SELECT attachment_base64 AS b FROM chat_local_messages WHERE id = ?', [r['id']]);
              final s = b.isEmpty ? null : b.first['b'] as String?;
              if (s != null) bytes = s.length >= _isolateMinBytes ? await compute(_base64DecodeIsolate, s) : base64Decode(s);
            } else {
              final src = File('${r['attachment_local_path']}');
              if (await src.exists()) bytes = await src.readAsBytes();
            }
            // Файл вложения (мегабайты фото) шифруем в изоляте — AES-GCM в главном изоляте держал кадр (отзыв 22.11).
            if (bytes != null) await target.writeAsBytes(await compute(_sealOneIsolate, <Object>[key, bytes]));
          }
          if (await target.exists()) file = fileName;
        }
        entries.add({
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
        dirs.add(dir.path);
      }
      // Все записи пачки шифруем одним заходом в изолят, а не по одной в UI.
      final sealed = await compute(_sealManyIsolate, <Object>[key, [for (final e in entries) utf8.encode(jsonEncode(e))]]);
      for (var i = 0; i < rows.length; i++) {
        final f = File(p.join(dirs[i], 'index.enc'));
        final len = ByteData(4)..setUint32(0, sealed[i].length);
        await f.writeAsBytes([...len.buffer.asUint8List(), ...sealed[i]], mode: FileMode.append, flush: true);
        // Курсор — по каждой реально записанной записи: прерванный проход
        // продолжается с неё и не дублирует уже сохранённое.
        cursor = rows[i]['rid'] as int;
        _put(db, _cursorKey, '$cursor');
        total++;
      }
      onProgress?.call(total, pending);
      await Future<void>.delayed(Duration.zero);
      if (budget != null && DateTime.now().difference(started) >= budget) break;
      if (rows.length < _batch) break;
    }
    return total;
  }

  /// Строки зашифрованного индекса `[длина(4) + блок]…` без расшифровки — чтобы
  /// читать их пачками в изоляте, а не всей папкой сразу.
  static List<Uint8List> _splitRecords(Uint8List data) {
    final out = <Uint8List>[];
    var pos = 0;
    final bd = ByteData.sublistView(data);
    while (pos + 4 <= data.length) {
      final len = bd.getUint32(pos);
      pos += 4;
      if (len <= 0 || pos + len > data.length) break;
      out.add(Uint8List.sublistView(data, pos, pos + len));
      pos += len;
    }
    return out;
  }

  /// Читает записи индекса: `[длина(4) + зашифрованный JSON]…`.
  static List<Map<String, dynamic>> _readRecords(Uint8List key, Uint8List data) {
    final out = <Map<String, dynamic>>[];
    var pos = 0;
    final bd = ByteData.sublistView(data);
    while (pos + 4 <= data.length) {
      final len = bd.getUint32(pos);
      pos += 4;
      if (len <= 0 || pos + len > data.length) break;
      try {
        out.add(jsonDecode(utf8.decode(_openBytes(key, Uint8List.sublistView(data, pos, pos + len)))) as Map<String, dynamic>);
      } catch (_) {}
      pos += len;
    }
    return out;
  }

  static ChatMessage _message(Map<String, dynamic> e, String contactId, String? b64, String? localPath) => ChatMessage(
        id: const Uuid().v4(),
        clientMessageId: '${e['cid']}',
        contactId: contactId,
        direction: e['dir'] == 'outgoing' ? ChatMessageDirection.outgoing : ChatMessageDirection.incoming,
        status: ChatMessageStatus.delivered,
        type: ChatMessageType.values.where((t) => t.name == e['type']).firstOrNull ?? ChatMessageType.text,
        text: e['text'] as String?,
        attachmentBase64: b64,
        attachmentName: e['name'] as String?,
        attachmentMime: e['mime'] as String?,
        attachmentSize: (e['size'] as num?)?.toInt(),
        attachmentLocalPath: localPath,
        replyToPreview: e['reply'] as String?,
        senderId: e['sender'] as String?,
        createdAt: DateTime.tryParse('${e['at']}') ?? DateTime.now(),
      );

  /// Читает папку и добавляет в чат то, чего ещё нет (по client id сообщения). Возвращает число
  /// восстановленных сообщений. Нет доступа к файлам или пароля — исключение.
  ///
  /// [onProgress] — (восстановлено, всего найдено), [cancelled] — кнопка
  /// «Отмена»: останавливаемся на границе пачки, уже налитое остаётся в базе.
  static Future<int> restore(LocalDbService db, ChatMessagesRepository repo,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    if (!await _root.exists()) return 0;
    final key = await _loadKey();
    final known = {for (final c in repo.listContacts()) c.id};
    // Уже сохранённые client id — одним запросом вместо `existsByClientId` на
    // каждое сообщение (индекса по client_message_id нет): на тысячах строк это
    // минуты работы в главном изоляте — отсюда «приложение не отвечает» (отзыв 22.11).
    final seen = <String>{
      for (final r in db.db.select('SELECT client_message_id AS cid FROM chat_local_messages')) '${r['cid']}'
    };

    void ensureContact(String id, String? nick) {
      if (known.add(id)) {
        repo.addContact(ChatContact(id: id, nickname: nick ?? 'Контакт', chatCode: '', addedAt: DateTime.now()));
      }
    }

    // 1. Сначала читаем индексы (расшифровка — пачками в изоляте), затем вливаем:
    //    так «всего M» известно сразу и прогресс честный.
    final items = <_VaultItem>[];
    var stopped = false;
    await for (final entity in _root.list()) {
      if (cancelled?.call() == true) {
        stopped = true;
        break;
      }
      if (entity is! Directory) continue;
      final encMeta = File(p.join(entity.path, 'contact.enc'));
      final encIndex = File(p.join(entity.path, 'index.enc'));
      if (await encMeta.exists() && await encIndex.exists()) {
        if (key == null) throw StateError('не задан пароль папки');
        final Map<String, dynamic> meta;
        try {
          meta = jsonDecode(utf8.decode(_openBytes(key, await encMeta.readAsBytes()))) as Map<String, dynamic>;
        } catch (_) {
          continue; // чужой пароль/порча папки: остальные папки всё равно восстанавливаем
        }
        final contactId = '${meta['id']}';
        ensureContact(contactId, meta['nickname'] as String?);
        final records = _splitRecords(await encIndex.readAsBytes());
        for (var i = 0; i < records.length; i += _batch) {
          if (cancelled?.call() == true) {
            stopped = true;
            break;
          }
          final end = i + _batch > records.length ? records.length : i + _batch;
          final texts = await compute(_openManyIsolate, <Object>[key, records.sublist(i, end)]);
          for (final t in texts) {
            if (t.isEmpty) continue;
            try {
              final e = jsonDecode(t) as Map<String, dynamic>;
              final cid = '${e['cid']}';
              if (cid.isEmpty || !seen.add(cid)) continue;
              items.add(_VaultItem(entity.path, contactId, e, encrypted: true));
            } catch (_) {}
          }
          await Future<void>.delayed(Duration.zero);
        }
        if (stopped) break;
        continue;
      }
      // Прежний открытый формат (до шифрования): читаем один раз, дальше он заменяется зашифрованным.
      final metaFile = File(p.join(entity.path, 'contact.json'));
      final indexFile = File(p.join(entity.path, 'index.jsonl'));
      if (!await metaFile.exists() || !await indexFile.exists()) continue;
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final contactId = '${meta['id']}';
      ensureContact(contactId, meta['nickname'] as String?);
      for (final raw in await indexFile.readAsLines()) {
        if (raw.trim().isEmpty) continue;
        try {
          final e = jsonDecode(raw) as Map<String, dynamic>;
          final cid = '${e['cid']}';
          if (cid.isEmpty || !seen.add(cid)) continue;
          items.add(_VaultItem(entity.path, contactId, e, encrypted: false));
        } catch (_) {}
      }
    }

    // 2. Вливаем пачками: одна транзакция и ОДИН пересчёт непрочитанных на пачку
    //    вместо COUNT(*) на каждое входящее (отзыв 22.11).
    final total = items.length;
    onProgress?.call(0, total);
    var restored = 0;
    final batch = <ChatMessage>[];
    Future<void> flush() async {
      if (batch.isEmpty) return;
      _insertBatch(db, batch);
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
        String? b64, localPath;
        if (e['file'] != null) {
          final f = File(p.join(it.dirPath, '${e['file']}'));
          if (await f.exists()) {
            if (it.encrypted) {
              if (await f.length() <= _maxRestoreInline + 64) {
                final plain = await compute(_openOneIsolate, <Object>[key!, await f.readAsBytes()]);
                b64 = plain.length >= _isolateMinBytes ? await compute(base64Encode, plain) : base64Encode(plain);
              }
              // Крупнее — зашифрованное вложения напрямую с диска не открыть (как и раньше).
            } else if (await f.length() <= _maxRestoreInline) {
              final bytes = await f.readAsBytes();
              b64 = bytes.length >= _isolateMinBytes ? await compute(base64Encode, bytes) : base64Encode(bytes);
            } else {
              localPath = f.path;
            }
          }
        }
        batch.add(_message(e, it.contactId, b64, localPath));
        restored++;
        if (batch.length >= _batch) await flush();
      }
    } finally {
      // Пачка, не дождавшаяся предела, всё равно сохраняется: при отмене и
      // ошибке уже налитое остаётся (отзыв 22.11).
      await flush();
    }
    if (!stopped) {
      // Восстановленное уже в папке — не дописывать его туда второй раз.
      final maxRid = db.db.select('SELECT COALESCE(MAX(rowid), 0) AS m FROM chat_local_messages').first['m'];
      _put(db, _cursorKey, '$maxRid');
    }
    return restored;
  }

  /// Пачка вставок одной транзакцией, без COUNT(*) на каждую строку. Колонки —
  /// те же, что пишет `ChatMessagesRepository.addMessage`; пишем напрямую,
  /// потому что его пересчёт непрочитанных на строку и есть блокировка UI
  /// (отзыв 22.11).
  static void _insertBatch(LocalDbService db, List<ChatMessage> batch) {
    var inTx = false;
    try {
      db.db.execute('BEGIN');
      inTx = true;
    } catch (_) {}
    try {
      for (final m in batch) {
        try {
          db.db.execute(
            'INSERT INTO chat_local_messages '
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
        } catch (_) {
          // Одна битая запись не должна ронять весь пакет.
        }
      }
    } finally {
      if (inTx) {
        try {
          db.db.execute('COMMIT');
        } catch (_) {
          // Коммит не прошёл — закрываем транзакцию откатом, иначе она останется
          // открытой и заблокирует следующие записи.
          try {
            db.db.execute('ROLLBACK');
          } catch (_) {}
        }
      }
    }
  }

  /// Старые открытые копии (папки с `contact.json`) — до включения шифрования.
  static Future<List<Directory>> _legacyDirs() async {
    final out = <Directory>[];
    if (!await _root.exists()) return out;
    await for (final e in _root.list()) {
      if (e is Directory && await File(p.join(e.path, 'contact.json')).exists()) out.add(e);
    }
    return out;
  }

  /// Включение шифрования поверх старой открытой папки: забираем из неё всё в приложение,
  /// заново сохраняем зашифрованным и удаляем открытые копии.
  static Future<void> migrateLegacy(LocalDbService db, ChatMessagesRepository repo,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {
    final legacy = await _legacyDirs();
    if (legacy.isEmpty) return;
    await restore(db, repo, onProgress: onProgress, cancelled: cancelled);
    _put(db, _cursorKey, '0');
    await sync(db, onProgress: onProgress, cancelled: cancelled);
    // Если проход отменили/прервали, открытые копии не удаляем: иначе потеряем
    // то, что ещё не успели переписать зашифрованным (отзыв 22.11).
    if (cancelled?.call() == true) return;
    for (final d in legacy) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  }
}
