// Базовый smoke-тест: приложение поднимается на in-memory БД и
// показывает главный экран.
//
// Раньше тест ждал экран подключения к базе — он был стартовым. Теперь
// приложение открывается сразу на рабочем экране: подключение к
// облаку переехало в настройки, и требовать его при каждом запуске
// было незачем (локальная база работает и без него).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  testWidgets('ShootingApp запускается и показывает главный экран', (WidgetTester tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');

    await tester.pumpWidget(ShootingApp(db: db));
    await tester.pump();

    // Нижняя навигация (HomeTabsBar) — то, что есть на любом стартовом
    // экране независимо от роли: значки видны всегда, подпись — только
    // у выбранной вкладки (та же экономия места, что была у
    // NavigationBar.onlyShowSelected), поэтому проверяем иконки, а не
    // текст всех вкладок разом.
    expect(find.byIcon(Icons.gps_fixed), findsOneWidget); // "Мишень" — стартовая вкладка
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
