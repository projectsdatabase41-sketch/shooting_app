import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';
import 'package:shooting_app/widgets/role_split.dart';

Widget _screen(String t, Widget? top) => Scaffold(body: Column(children: [if (top != null) top, Text(t)]));

void main() {
  testWidgets('обе роли: общий список «Чьи данные» (Я + спортсмены); одна роль — списка нет, кнопки М/С нет', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..isAthlete = true..isCoach = true;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        home: RoleSplit(
          perAthlete: false,
          athlete: (top) => _screen('Мои данные', top),
          coach: (top, _) => _screen('Данные спортсменов', top),
        ),
      ),
    ));
    expect(find.text('Мои данные'), findsOneWidget);
    expect(find.text('Чьи данные'), findsOneWidget);
    expect(store.workMode, WorkMode.athlete);
    expect(find.text('М'), findsNothing); // кнопки в шапке больше нет

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Мои спортсмены').last);
    await tester.pumpAndSettle();
    expect(find.text('Данные спортсменов'), findsOneWidget);
    expect(store.workMode, WorkMode.coach);

    store.isCoach = false; // одна роль: ни списка, ни кнопки
    store.refreshView();
    await tester.pump();
    expect(find.text('Чьи данные'), findsNothing);
    expect(find.text('Мои данные'), findsOneWidget);
  });
}
