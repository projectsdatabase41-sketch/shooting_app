import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';
import 'package:shooting_app/widgets/glass_pill.dart';
import 'package:shooting_app/widgets/role_split.dart';

Widget _screen(String t) => Scaffold(appBar: GlassHeader(leading: const SizedBox.shrink(), title: Text(t)));

void main() {
  testWidgets('обе роли: в шапке круглая кнопка М/С переключает части; одна роль — кнопки нет', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..isAthlete = true..isCoach = true;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(home: RoleSplit(athlete: _screen('Мои данные'), coach: _screen('Данные спортсменов'))),
    ));
    expect(find.text('М'), findsOneWidget);
    expect(find.text('Мои данные'), findsOneWidget);
    await tester.tap(find.text('М'));
    await tester.pumpAndSettle();
    expect(find.text('М — Мои'), findsOneWidget); // выдвинулся список из двух строк
    expect(find.text('С — Спортсмены'), findsOneWidget);
    await tester.tap(find.text('С — Спортсмены'));
    await tester.pumpAndSettle();
    expect(find.text('М — Мои'), findsNothing); // выбор закрыл список
    expect(find.text('С'), findsOneWidget);
    expect(store.workMode, WorkMode.coach);
    await tester.tap(find.text('С'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('М — Мои'));
    await tester.pumpAndSettle();
    expect(find.text('М'), findsOneWidget);
    expect(store.workMode, WorkMode.athlete);

    store.isCoach = false; // одна роль
    store.refreshView();
    await tester.pump();
    expect(find.text('М'), findsNothing);
    expect(find.text('С'), findsNothing);
  });
}
