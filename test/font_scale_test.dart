import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';

// Отдельный файл: второй ShootingApp в одном файле с другим тестом зависает
// из-за остаточных таймеров первого (особенность тестовой среды).
void main() {
  testWidgets('крупный системный шрифт (1.8) не ломает главный экран',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    await tester.pumpWidget(ShootingApp(db: db, requireProfile: false));
    await tester.pump();
    final ex = tester.takeException();
    if (ex != null) {
      throw ex;
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
