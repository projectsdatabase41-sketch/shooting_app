import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/screens/import_screen.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';
import 'package:shooting_app/state/personalization_view_model.dart';

void main() {
  testWidgets('экран импорта открывается и предлагает выбрать файлы', (tester) async {
    final db = LocalDbService();
    await tester.runAsync(() => db.open(overridePath: ':memory:'));
    final store = AppDataStore(db)..loadAll();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider(create: (_) => PersonalizationViewModel(db)..loadFromDb()),
      ],
      child: const MaterialApp(home: ImportScreen()),
    ));
    await tester.pump();
    expect(find.text('Выбрать файлы'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
