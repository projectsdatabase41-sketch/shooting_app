import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:pointycastle/export.dart';

/// Ключ из пароля: PBKDF2-HMAC-SHA256. Тяжёлый расчёт уходит в отдельный поток, чтобы не вешать экран.
class Kdf {
  Kdf._();

  static Uint8List randomBytes(int n) {
    final r = math.Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  static Uint8List _derive(List<Object> a) {
    final pw = a[0] as String;
    final salt = a[1] as Uint8List;
    final iterations = a[2] as int;
    final len = a[3] as int;
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(salt, iterations, len));
    return d.process(Uint8List.fromList(utf8.encode(pw)));
  }

  static Future<Uint8List> derive(String password, Uint8List salt, {int iterations = 60000, int length = 32}) =>
      compute(_derive, <Object>[password, salt, iterations, length]);

  /// Сравнение без досрочного выхода.
  static bool equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var x = 0;
    for (var i = 0; i < a.length; i++) {
      x |= a[i] ^ b[i];
    }
    return x == 0;
  }
}
