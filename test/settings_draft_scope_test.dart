import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/widgets/settings_draft_scope.dart';

void main() {
  Future<(LocalDbService, bool Function())> setup(WidgetTester tester) async {
    final db = LocalDbService();
    await tester.runAsync(() => db.open(overridePath: ':memory:'));
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('a', '1')");
    var restored = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => SettingsDraftScope(
                  db: db,
                  onRestored: () => restored = true,
                  child: Scaffold(
                    appBar: AppBar(
                      actions: [Builder(builder: (c) => SettingsDraftScope.confirmButton(c))],
                    ),
                    body: TextButton(
                      key: const Key('change'),
                      onPressed: () {
                        db.db.execute("UPDATE color_prefs SET hex = '2' WHERE key = 'a'");
                        db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('b', 'x')");
                      },
                      child: const Text('change'),
                    ),
                  ),
                ),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (db, () => restored);
  }

  String? val(LocalDbService db, String k) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  testWidgets('«Назад» возвращает настройки как были', (tester) async {
    final (db, restored) = await setup(tester);
    await tester.tap(find.byKey(const Key('change')));
    expect(val(db, 'a'), '2');
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(val(db, 'a'), '1');
    expect(val(db, 'b'), isNull);
    expect(restored(), isTrue);
    expect(find.text('open'), findsOneWidget); // экран закрыт
  });

  testWidgets('галочка сохраняет изменения и закрывает экран', (tester) async {
    final (db, restored) = await setup(tester);
    await tester.tap(find.byKey(const Key('change')));
    await tester.tap(find.byTooltip('Сохранить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(val(db, 'a'), '2');
    expect(val(db, 'b'), 'x');
    expect(restored(), isFalse);
    expect(find.text('open'), findsOneWidget);
  });
}
