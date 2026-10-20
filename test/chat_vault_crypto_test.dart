import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/chat_vault_io.dart';
import 'package:shooting_app/services/kdf.dart';

void main() {
  test('пароль → ключ: тот же пароль и соль дают тот же ключ, другой пароль — другой', () async {
    final salt = Kdf.randomBytes(16);
    final a = await Kdf.derive('пароль-1234', salt, iterations: 1000);
    final b = await Kdf.derive('пароль-1234', salt, iterations: 1000);
    final c = await Kdf.derive('пароль-1235', salt, iterations: 1000);
    expect(Kdf.equal(a, b), isTrue);
    expect(Kdf.equal(a, c), isFalse);
    expect(a.length, 32);
  });

  test('файлы и записи индекса: шифруются, читаются тем же ключом, чужой ключ и порча не проходят', () async {
    final key = await Kdf.derive('secret-pass', Kdf.randomBytes(16), iterations: 1000);
    final other = await Kdf.derive('another-pass', Kdf.randomBytes(16), iterations: 1000);
    final data = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final sealed = ChatVault.sealForTest(key, data);
    expect(sealed.length, greaterThan(data.length));
    expect(ChatVault.openForTest(key, sealed), data);
    expect(() => ChatVault.openForTest(other, sealed), throwsA(anything));
    final broken = Uint8List.fromList(sealed)..[20] ^= 1;
    expect(() => ChatVault.openForTest(key, broken), throwsA(anything));

    // индекс: две записи подряд, как их дописывает sync
    Uint8List record(Map<String, dynamic> e) {
      final s = ChatVault.sealForTest(key, utf8.encode(jsonEncode(e)));
      final len = ByteData(4)..setUint32(0, s.length);
      return Uint8List.fromList([...len.buffer.asUint8List(), ...s]);
    }

    final file = Uint8List.fromList([...record({'cid': 'a', 'text': 'привет'}), ...record({'cid': 'b', 'text': 'пока'})]);
    final read = ChatVault.readRecordsForTest(key, file);
    expect(read.map((e) => e['cid']), ['a', 'b']);
    expect(read.first['text'], 'привет');
    expect(ChatVault.readRecordsForTest(other, file), isEmpty);
  });
}
