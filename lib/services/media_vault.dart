import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'call_service.dart';
import 'chat_auth_service.dart';
import 'local_db_service.dart';

/// Медиа чата через R2: **шифрование на устройстве**, приватный бакет,
/// квоты считает сервер звонков (см. `/media/upload` в cloud/calls-worker).
///
/// Схема ключей: у каждого пользователя своя пара X25519. Открытый ключ
/// публикуется в переписке (сообщение `NX1:pk:…`), приватный никогда не
/// покидает устройство. Из общего секрета (X25519 + HKDF-SHA256) выводится
/// ключ AES-256-GCM, которым шифруется файл. В R2 уходит только шифротекст,
/// в базу чата — только идентификатор объекта (128-битный случайный ключ),
/// поэтому ни Cloudflare, ни Postgres открытый файл не видят.
///
/// Лимиты (8 ГБ на бакет, 1 ГБ на человека в месяц, 25 МБ на файл) проверяет
/// сервер. При отказе (`413`) метод молча возвращает null — вызывающий код
/// отправляет старым путём, и пользователь ничего не замечает.
class MediaVault {
  MediaVault(this.db, this.auth);

  final LocalDbService db;
  final ChatAuthService auth;

  static const _kPriv = 'media_x25519_priv';
  static const _kPub = 'media_x25519_pub';
  static const _hkdfInfo = 'nexus-media-v1';

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _keyPair;
  SimplePublicKey? _publicKey;

  // ---- Хранилище ключей (та же key-value таблица, что у темы) ----

  String _read(String key) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return rows.isEmpty ? '' : '${rows.first['hex'] ?? ''}';
  }

  void _write(String key, String value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, value],
    );
  }

  /// Создаёт пару ключей при первом обращении. Приватный ключ — в локальной
  /// базе устройства (она и так под PIN/шифрованием ОС), в облако не уходит.
  Future<SimplePublicKey> ensureKeys() async {
    if (_publicKey != null) return _publicKey!;
    final privHex = _read(_kPriv);
    final seed = privHex.isEmpty ? null : _hexToBytes(privHex);
    if (seed != null && seed.length == 32) {
      _keyPair = await _x25519.newKeyPairFromSeed(seed);
    } else {
      _keyPair = await _x25519.newKeyPair();
      final extracted = await _keyPair!.extractPrivateKeyBytes();
      _write(_kPriv, _bytesToHex(extracted));
    }
    _publicKey = await _keyPair!.extractPublicKey();
    _write(_kPub, base64Encode(_publicKey!.bytes));
    return _publicKey!;
  }

  /// Открытый ключ в base64 — его и публикуем собеседнику.
  Future<String> publicKeyBase64() async => base64Encode((await ensureKeys()).bytes);

  /// Сообщение-служебка с открытым ключом (отдельный префикс, чтобы старые
  /// версии приложения просто показали текст, а не сломались).
  Future<String> keyMessage() async => 'NX1:pk:${await publicKeyBase64()}';

  /// Разобрать открытый ключ собеседника из служебного сообщения.
  static SimplePublicKey? parseKeyMessage(String text) {
    if (!text.startsWith('NX1:pk:')) return null;
    try {
      final bytes = base64Decode(text.substring('NX1:pk:'.length).trim());
      if (bytes.length != 32) return null;
      return SimplePublicKey(bytes, type: KeyPairType.x25519);
    } catch (_) {
      return null;
    }
  }

  Future<SecretKey> _sharedKey(SimplePublicKey peer) async {
    final mine = await ensureKeys();
    final pair = _keyPair!;
    final shared = await _x25519.sharedSecretKey(keyPair: pair, remotePublicKey: peer);
    return _hkdf.deriveKey(secretKey: shared, nonce: const [], info: utf8.encode(_hkdfInfo));
  }

  // ---- Шифрование файла ----

  /// Шифрует файл: возвращает `nonce(12) | mac(16) | ciphertext`.
  Future<Uint8List> encrypt(Uint8List clear, SimplePublicKey peer) async {
    final key = await _sharedKey(peer);
    final box = await _aes.encrypt(clear, secretKey: key);
    return Uint8List.fromList(box.concatenation());
  }

  /// Расшифровывает то, что вернул [encrypt].
  Future<Uint8List> decrypt(Uint8List data, SimplePublicKey peer) async {
    final key = await _sharedKey(peer);
    final box = SecretBox.fromConcatenation(data,
        nonceLength: 12, macLength: 16);
    final clear = await _aes.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  }

  // ---- Обмен с сервером звонков ----

  /// Кладёт шифротекст в R2. Возвращает идентификатор объекта (32 hex) или
  /// null — если сервер не дал (нет входа, квота, сеть). Вызывающий код в
  /// этом случае просто отправляет файл старым путём.
  Future<String?> upload(Uint8List encrypted) async {
    if (encrypted.isEmpty) return null;
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    final key = _randomHex(16);
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('${CallService.url}/media/upload'),
            headers: {
              'Authorization': 'Bearer $token',
              'x-media-key': key,
              'content-type': 'application/octet-stream',
            },
            body: encrypted,
          )
          .timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) return null;
      return key;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Забирает шифротекст из R2 по идентификатору.
  Future<Uint8List?> download(String key) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('${CallService.url}/media/$key'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Сколько занято (байты) — для диагностики, в интерфейсе не показываем.
  Future<Map<String, dynamic>?> usage() async {
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('${CallService.url}/media/usage'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static String _randomHex(int bytes) {
    final rnd = Random.secure();
    final out = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      out.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
