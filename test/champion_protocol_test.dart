import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/screens/final_run_screen.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  testWidgets('протокол чемпиона: серии и выстрелы показываются, кнопки публикации нет', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final shots = [for (var i = 0; i < 24; i++) 10.0 + (i % 10) / 10];
    final rec = {
      'format': 'air_rifle_10m',
      'face': '',
      'standings': [
        {'id': 'p', 'name': 'Анна Чемпионова', 'place': 1, 'total': 250.0, 'user': true},
      ],
      'shots': [for (var i = 0; i < shots.length; i++) {'who': 'p', 'i': i, 's': shots[i]}],
    };
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppDataStore(db),
      child: MaterialApp(home: FinalResultScreen(record: rec, readOnly: true, title: 'Анна Чемпионова')),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Анна Чемпионова'), findsWidgets);
    expect(find.text('C1'), findsOneWidget);
    expect(find.text('C2'), findsOneWidget);
    expect(find.textContaining('Опубликовать'), findsNothing);
    expect(find.textContaining('Средний выстрел'), findsNothing);
  });
}
