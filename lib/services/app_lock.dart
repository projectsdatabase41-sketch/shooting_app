import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'kdf.dart';
import 'local_db_service.dart';
import 'secret_box.dart';

/// Защита входа в приложение: PIN (4–8 цифр) и, по желанию, биометрия.
///
/// PIN не хранится: в базе лежит соль и результат PBKDF2 (в зашифрованном виде, см. [SecretBox]).
/// Неверные попытки замедляются: после 5-й подряд — пауза, дальше всё дольше.
class AppLock {
  AppLock._();

  static const _pinKey = 'applock_pin';
  static const _bioKey = 'applock_bio';
  static const _delayKey = 'applock_delay';
  static const _failsKey = 'applock_fails';
  static const _untilKey = 'applock_until';
  static const _iterations = 40000;
  static const _lenKey = 'applock_len';
  static const _methodKey = 'applock_method';
  static const _bioAutoKey = 'applock_bio_auto';

  /// Экран блокировки сейчас показан.
  static final locked = ValueNotifier<bool>(false);
  static DateTime? _pausedAt;

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static bool isEnabled(LocalDbService db) => (_get(db, _pinKey) ?? '').isNotEmpty;

  /// Чем вход защищён: 'pin' или 'pattern' (графический ключ).
  static String method(LocalDbService db) => _get(db, _methodKey) == 'pattern' ? 'pattern' : 'pin';

  /// Сразу показывать системное окно отпечатка при открытии (по умолчанию нет: сначала наш экран,
  /// отпечаток — по кнопке). Окно отпечатка рисует сама система, заменить его нельзя.
  static bool biometricAuto(LocalDbService db) => _get(db, _bioAutoKey) == '1';
  static void setBiometricAuto(LocalDbService db, bool v) => _put(db, _bioAutoKey, v ? '1' : '0');

  static bool biometricOn(LocalDbService db) => isEnabled(db) && _get(db, _bioKey) == '1';
  static void setBiometric(LocalDbService db, bool v) => _put(db, _bioKey, v ? '1' : '0');

  /// Через сколько секунд после сворачивания просить вход снова (0 — сразу).
  static int delaySec(LocalDbService db) => int.tryParse(_get(db, _delayKey) ?? '') ?? 0;
  static void setDelaySec(LocalDbService db, int s) => _put(db, _delayKey, '$s');

  /// Длина PIN (проверка идёт сама, когда набрано столько цифр).
  static int pinLength(LocalDbService db) => (int.tryParse(_get(db, _lenKey) ?? '') ?? 4).clamp(4, 8);

  static bool validPin(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  /// Графический ключ — номера точек 0…8 подряд, без повторов, от 4 до 9 точек.
  static bool validPattern(String p) => RegExp(r'^[0-8]{4,9}$').hasMatch(p) && p.split('').toSet().length == p.length;

  static Future<void> setPattern(LocalDbService db, String pattern) async {
    await setPin(db, pattern);
    _put(db, _methodKey, 'pattern');
  }

  static Future<void> setPin(LocalDbService db, String pin) async {
    _put(db, _methodKey, 'pin');
    final salt = Kdf.randomBytes(16);
    final hash = await Kdf.derive(pin, salt, iterations: _iterations);
    _put(db, _pinKey, SecretBox.seal('v1:${base64Encode(salt)}:${base64Encode(hash)}'));
    _put(db, _lenKey, '${pin.length}');
    _put(db, _failsKey, '0');
    _put(db, _untilKey, '');
  }

  static void disable(LocalDbService db) {
    _put(db, _pinKey, '');
    _put(db, _bioKey, '0');
    _put(db, _failsKey, '0');
    _put(db, _untilKey, '');
    locked.value = false;
  }

  /// Сколько ещё ждать до следующей попытки; `null` — можно вводить.
  static Duration? lockoutLeft(LocalDbService db) {
    final until = DateTime.tryParse(_get(db, _untilKey) ?? '');
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  static Future<bool> verify(LocalDbService db, String pin) async {
    if (lockoutLeft(db) != null) return false;
    final stored = SecretBox.open(_get(db, _pinKey) ?? '');
    final parts = stored.split(':');
    var ok = false;
    if (parts.length == 3 && parts[0] == 'v1') {
      final hash = await Kdf.derive(pin, base64Decode(parts[1]), iterations: _iterations);
      ok = Kdf.equal(hash, base64Decode(parts[2]));
    }
    if (ok) {
      _put(db, _failsKey, '0');
      _put(db, _untilKey, '');
      return true;
    }
    final fails = (int.tryParse(_get(db, _failsKey) ?? '') ?? 0) + 1;
    _put(db, _failsKey, '$fails');
    if (fails >= 5) {
      final secs = (30 * (1 << (fails - 5).clamp(0, 5))).clamp(30, 900);
      _put(db, _untilKey, DateTime.now().add(Duration(seconds: secs)).toIso8601String());
    }
    return false;
  }

  static Future<bool> biometricAvailable() async {
    try {
      final a = LocalAuthentication();
      return await a.isDeviceSupported() && await a.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> biometricAuth(String reason) async {
    try {
      return await LocalAuthentication().authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// При запуске приложения.
  static void lockOnStart(LocalDbService db) {
    if (isEnabled(db)) locked.value = true;
  }

  static void onPaused() => _pausedAt = DateTime.now();

  static void onResumed(LocalDbService db) {
    final at = _pausedAt;
    _pausedAt = null;
    if (!isEnabled(db) || at == null || locked.value) return;
    if (DateTime.now().difference(at).inSeconds >= delaySec(db)) locked.value = true;
  }
}
