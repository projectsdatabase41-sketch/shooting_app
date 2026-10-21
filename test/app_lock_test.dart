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

  test('графический ключ: проверка формата, хранение хешем, способ входа, смена на PIN', () async {
    expect(AppLock.validPattern('0124'), isTrue);
    expect(AppLock.validPattern('012'), isFalse); // меньше 4 точек
    expect(AppLock.validPattern('0120'), isFalse); // повтор точки
    expect(AppLock.validPattern('01239'), isFalse); // нет такой точки
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    expect(AppLock.method(db), 'pin');
    await AppLock.setPattern(db, '01258');
    expect(AppLock.method(db), 'pattern');
    expect(AppLock.isEnabled(db), isTrue);
    final stored = db.db.select("SELECT hex FROM color_prefs WHERE key = 'applock_pin'").first['hex'] as String;
    expect(stored.contains('01258'), isFalse);
    expect(await AppLock.verify(db, '01258'), isTrue);
    expect(await AppLock.verify(db, '85210'), isFalse);
    await AppLock.setPin(db, '4321');
    expect(AppLock.method(db), 'pin');
    expect(await AppLock.verify(db, '4321'), isTrue);
    expect(AppLock.biometricAuto(db), isFalse); // системное окно отпечатка само не выезжает
  });
}
