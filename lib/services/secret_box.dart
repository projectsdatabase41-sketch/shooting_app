import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_db_service.dart';

/// Шифрование секретов (токены входа, ключи ИИ, пароль моста Google Диска) в локальной базе.
///
/// Ключ AES-256 лежит в защищённом хранилище системы (Android Keystore / iOS Keychain) и
/// никогда не попадает в SQLite. Значения хранятся как `enc1:<base64(iv + шифртекст + тег)>` (AES-GCM):
/// копия файла базы без ключа телефона — бесполезна. Если защищённое хранилище недоступно
/// (тесты, редкие сбои), работает без шифрования — как раньше. Старые значения без префикса
/// читаются как есть и шифруются при следующей записи или при [migrate].
class SecretBox {
  SecretBox._();

  static const _prefix = 'enc1:';
  static const _keyName = 'nexus_secret_key_v1';
  static Uint8List? _key;

  static bool get ready => _key != null;

  @visibleForTesting
  static void useKeyForTest(Uint8List? key) => _key = key;

  /// Вызывается один раз при запуске, до чтения секретов.
  static Future<void> init() async {
    try {
      const storage = FlutterSecureStorage();
      var k = await storage.read(key: _keyName);
      if (k == null || k.isEmpty) {
        k = base64Encode(enc.SecureRandom(32).bytes);
        await storage.write(key: _keyName, value: k);
      }
      _key = base64Decode(k);
    } catch (_) {
      _key = null;
    }
  }

  /// Зашифровать значение для записи в базу. Пустое и уже зашифрованное не трогаем.
  static String seal(String plain) {
    final key = _key;
    if (key == null || plain.isEmpty || plain.startsWith(_prefix)) return plain;
    final iv = enc.IV.fromSecureRandom(12);
    final box = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    final out = box.encryptBytes(utf8.encode(plain), iv: iv);
    return '$_prefix${base64Encode([...iv.bytes, ...out.bytes])}';
  }

  /// Расшифровать значение из базы. Старое (без префикса) возвращается как есть; не удалось
  /// расшифровать (ключ утерян) — пустая строка: пользователю придётся войти заново.
  static String open(String stored) {
    if (!stored.startsWith(_prefix)) return stored;
    final key = _key;
    if (key == null) return '';
    try {
      final raw = base64Decode(stored.substring(_prefix.length));
      final box = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
      return utf8.decode(box.decryptBytes(enc.Encrypted(Uint8List.fromList(raw.sublist(12))), iv: enc.IV(Uint8List.fromList(raw.sublist(0, 12)))));
    } catch (_) {
      return '';
    }
  }

  /// Колонки `project_settings` и ключи `color_prefs`, значения которых — секреты.
  static const settingsColumns = {'auth_access_token', 'auth_refresh_token', 'chat_access_token', 'chat_refresh_token', 'coach_share_token'};
  static const prefKeys = {'ai_api_key', 'ai_gemini_key', 'gdrive_secret'};

  /// Один раз после [init]: шифрует то, что уже лежит в базе открытым текстом.
  static void migrate(LocalDbService db) {
    if (!ready) return;
    try {
      for (final c in settingsColumns) {
        final r = db.db.select('SELECT $c AS v FROM project_settings WHERE id = 1');
        final v = r.isEmpty ? null : r.first['v'] as String?;
        if (v != null && v.isNotEmpty && !v.startsWith(_prefix)) {
          db.db.execute('UPDATE project_settings SET $c = ? WHERE id = 1', [seal(v)]);
        }
      }
      for (final k in prefKeys) {
        final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
        final v = r.isEmpty ? null : r.first['hex'] as String?;
        if (v != null && v.isNotEmpty && !v.startsWith(_prefix)) {
          db.db.execute('UPDATE color_prefs SET hex = ? WHERE key = ?', [seal(v), k]);
        }
      }
    } catch (_) {}
  }
}
