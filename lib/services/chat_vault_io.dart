import 'app_lock.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  static Uint8List _sealBytes(Uint8List key, List<int> plain) {
    final iv = enc.IV.fromSecureRandom(12);
    final out = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm)).encryptBytes(plain, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...out.bytes]);
  }

  static Uint8List _openBytes(Uint8List key, List<int> data) {
    final raw = Uint8List.fromList(data);
    final out = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm))
        .decryptBytes(enc.Encrypted(Uint8List.sublistView(raw, 12)), iv: enc.IV(Uint8List.sublistView(raw, 0, 12)));
    return Uint8List.fromList(out);
  }

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

  static Future<void> syncIfOn(LocalDbService db) async {
    if (!isOn(db)) return;
    try {
      if (!(await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted)) return;
      if (await _loadKey() == null) return; // пароль ещё не задан
      await sync(db);
    } catch (_) {}
  }

  static Future<void> _appendRecord(File f, Uint8List key, Map<String, dynamic> entry) async {
    final sealed = _sealBytes(key, utf8.encode(jsonEncode(entry)));
    final len = ByteData(4)..setUint32(0, sealed.length);
    await f.writeAsBytes([...len.buffer.asUint8List(), ...sealed], mode: FileMode.append, flush: true);
  }

  /// Дописывает в папку всё новое с прошлого раза (по порядку записи сообщений на телефоне).
  /// Возвращает число сохранённых сообщений.
  static Future<int> sync(LocalDbService db) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    final key = await _loadKey();
    if (key == null) throw StateError('не задан пароль папки');
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
        final dir = Directory(p.join(_root.path, _folderOf(key, '${r['contact_id']}')));
        await dir.create(recursive: true);
        final meta = File(p.join(dir.path, 'contact.enc'));
        if (!await meta.exists()) {
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
              if (s != null) bytes = base64Decode(s);
            } else {
              final src = File('${r['attachment_local_path']}');
              if (await src.exists()) bytes = await src.readAsBytes();
            }
            if (bytes != null) await target.writeAsBytes(_sealBytes(key, bytes));
          }
          if (await target.exists()) file = fileName;
        }
        await _appendRecord(File(p.join(dir.path, 'index.enc')), key, {
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
        total++;
        _put(db, _cursorKey, '${r['rid']}');
      }
      if (rows.length < 100) break;
    }
    return total;
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
  static Future<int> restore(LocalDbService db, ChatMessagesRepository repo) async {
    if (!await ensureAccess()) throw StateError('нет доступа к файлам');
    if (!await _root.exists()) return 0;
    final key = await _loadKey();
    var restored = 0;
    final known = {for (final c in repo.listContacts()) c.id};

    void ensureContact(String id, String? nick) {
      if (known.add(id)) {
        repo.addContact(ChatContact(id: id, nickname: nick ?? 'Контакт', chatCode: '', addedAt: DateTime.now()));
      }
    }

    await for (final entity in _root.list()) {
      if (entity is! Directory) continue;
      final encMeta = File(p.join(entity.path, 'contact.enc'));
      final encIndex = File(p.join(entity.path, 'index.enc'));
      if (await encMeta.exists() && await encIndex.exists()) {
        if (key == null) throw StateError('не задан пароль папки');
        final meta = jsonDecode(utf8.decode(_openBytes(key, await encMeta.readAsBytes()))) as Map<String, dynamic>;
        final contactId = '${meta['id']}';
        ensureContact(contactId, meta['nickname'] as String?);
        for (final e in _readRecords(key, await encIndex.readAsBytes())) {
          try {
            if (repo.existsByClientId('${e['cid']}')) continue;
            String? b64, localPath;
            if (e['file'] != null) {
              final f = File(p.join(entity.path, '${e['file']}'));
              if (await f.exists()) {
                if (await f.length() <= _maxRestoreInline + 64) {
                  b64 = base64Encode(_openBytes(key, await f.readAsBytes()));
                } else {
                  localPath = null; // крупные зашифрованные вложения напрямую с диска не открыть
                }
              }
            }
            repo.addMessage(_message(e, contactId, b64, localPath));
            restored++;
          } catch (_) {}
        }
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
          if (repo.existsByClientId('${e['cid']}')) continue;
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
          repo.addMessage(_message(e, contactId, b64, localPath));
          restored++;
        } catch (_) {}
      }
    }
    // Восстановленное уже в папке — не дописывать его туда второй раз.
    final maxRid = db.db.select('SELECT COALESCE(MAX(rowid), 0) AS m FROM chat_local_messages').first['m'];
    _put(db, _cursorKey, '$maxRid');
    return restored;
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
  static Future<void> migrateLegacy(LocalDbService db, ChatMessagesRepository repo) async {
    final legacy = await _legacyDirs();
    if (legacy.isEmpty) return;
    await restore(db, repo);
    _put(db, _cursorKey, '0');
    await sync(db);
    for (final d in legacy) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  }
}
