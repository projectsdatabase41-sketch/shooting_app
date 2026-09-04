// Базовый smoke-тест: приложение поднимается на in-memory БД и
// показывает экран подключения (первый экран по умолчанию).
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  testWidgets('ShootingApp запускается и показывает экран подключения', (WidgetTester tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');

    await tester.pumpWidget(ShootingApp(db: db));
    await tester.pump();

    expect(find.text('Подключение к базе'), findsOneWidget);
  });
}
