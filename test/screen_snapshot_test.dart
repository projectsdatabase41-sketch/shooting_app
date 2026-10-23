import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/demo_mode.dart';

void main() {
  testWidgets('снимок экрана: надписи и переключатели есть, поле ввода не читается', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [DemoRouteObserver.instance],
      home: Scaffold(
        body: Column(children: [
          const Text('Заголовок экрана'),
          Switch(value: true, onChanged: (_) {}),
          TextField(controller: TextEditingController(text: 'секретный пароль')),
        ]),
      ),
    ));
    final s = DemoMode.screenSnapshot();
    expect(s, contains('Заголовок экрана'));
    expect(s, contains('переключатель: вкл'));
    expect(s, isNot(contains('секретный пароль')));
  });
}
