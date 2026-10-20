import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/app_lock.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  test('PIN: хранится не открытым текстом, проверка, пауза после 5 неверных попыток, отключение', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    expect(AppLock.isEnabled(db), isFalse);
    expect(AppLock.validPin('123'), isFalse);
    expect(AppLock.validPin('12ab'), isFalse);
    expect(AppLock.validPin('123456'), isTrue);
    await AppLock.setPin(db, '123456');
    expect(AppLock.isEnabled(db), isTrue);
    expect(AppLock.pinLength(db), 6);
    final stored = db.db.select("SELECT hex FROM color_prefs WHERE key = 'applock_pin'").first['hex'] as String;
    expect(stored.contains('123456'), isFalse);
    expect(await AppLock.verify(db, '123456'), isTrue);
    for (var i = 0; i < 5; i++) {
      expect(await AppLock.verify(db, '000000'), isFalse);
    }
    expect(AppLock.lockoutLeft(db), isNotNull); // пауза: даже верный PIN сейчас не принимается
    expect(await AppLock.verify(db, '123456'), isFalse);
    AppLock.disable(db);
    expect(AppLock.isEnabled(db), isFalse);
    expect(AppLock.lockoutLeft(db), isNull);
  });
}
