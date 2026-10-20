import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/gdrive/gdrive_service.dart';
import 'package:shooting_app/services/ai_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/secret_box.dart';

void main() {
  tearDown(() => SecretBox.useKeyForTest(null));

  test('шифрование туда-обратно; без ключа и старые значения — как есть; чужой ключ не открывает', () {
    SecretBox.useKeyForTest(Uint8List.fromList(List.generate(32, (i) => i)));
    final sealed = SecretBox.seal('super-secret-token');
    expect(sealed.startsWith('enc1:'), isTrue);
    expect(sealed.contains('super-secret'), isFalse);
    expect(SecretBox.open(sealed), 'super-secret-token');
    expect(SecretBox.seal(sealed), sealed); // уже зашифровано — второй раз не трогаем
    expect(SecretBox.open('plain-old-value'), 'plain-old-value');
    expect(SecretBox.seal(''), '');
    SecretBox.useKeyForTest(Uint8List.fromList(List.generate(32, (i) => 255 - i)));
    expect(SecretBox.open(sealed), ''); // другой ключ — пусто, а не мусор
    SecretBox.useKeyForTest(null);
    expect(SecretBox.seal('x'), 'x');
  });

  test('в базе секреты лежат зашифрованными, наружу читаются открытыми; миграция шифрует старое', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    // старое значение открытым текстом
    GDriveService.save(db, url: 'https://x', secret: 'oldpassword123');
    expect(db.db.select("SELECT hex FROM color_prefs WHERE key = 'gdrive_secret'").first['hex'], 'oldpassword123');
    SecretBox.useKeyForTest(Uint8List.fromList(List.generate(32, (i) => i + 1)));
    expect(GDriveService.secret(db), 'oldpassword123'); // читается и без шифрования
    SecretBox.migrate(db);
    final raw = db.db.select("SELECT hex FROM color_prefs WHERE key = 'gdrive_secret'").first['hex'] as String;
    expect(raw.startsWith('enc1:'), isTrue);
    expect(GDriveService.secret(db), 'oldpassword123');
    // новая запись сразу шифруется
    AiSettings(db).apiKey = 'sk-test-key';
    final rawKey = db.db.select("SELECT hex FROM color_prefs WHERE key = 'ai_api_key'").first['hex'] as String;
    expect(rawKey.contains('sk-test'), isFalse);
    expect(AiSettings(db).apiKey, 'sk-test-key');
  });
}
