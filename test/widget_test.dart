// Базовый smoke-тест: приложение поднимается на in-memory БД и
// показывает главный экран.
//
// Раньше тест ждал экран подключения к базе — он был стартовым. Теперь
// приложение открывается сразу на рабочем экране: подключение к
// облаку переехало в настройки, и требовать его при каждом запуске
// было незачем (локальная база работает и без него).
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  testWidgets('ShootingApp запускается и показывает главный экран', (WidgetTester tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');

    await tester.pumpWidget(ShootingApp(db: db));
    await tester.pump();

    // Нижняя навигация — то, что есть на любом стартовом экране
    // независимо от роли и от того, есть ли в базе упражнения.
    expect(find.text('Тренировка'), findsWidgets);
    expect(find.text('Настройки'), findsWidgets);
  });
}
