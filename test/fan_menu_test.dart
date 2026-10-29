import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/fan_menu.dart';

void main() {
  Widget app(List<String> log) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(120),
              child: FanButton(
                icon: const Icon(Icons.add),
                items: [
                  FanItem(label: 'A', child: const Text('A'), onSelect: () => log.add('A')),
                  FanItem(label: 'B', child: const Text('B'), onSelect: () => log.add('B')),
                  FanItem(label: 'C', child: const Text('C'), onSelect: () => log.add('C')),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('тап раскрывает веер, нажатие на пункт выбирает его и закрывает', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(app(log));
    expect(find.text('B'), findsNothing);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('B'), findsOneWidget);
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(log, ['B']);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('mirror: веер раскрывается вправо от кнопки, у левого края', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: FanButton(
              mirror: true,
              icon: const Icon(Icons.add),
              items: [
                for (final t in ['A', 'B', 'C', 'D', 'E', 'F'])
                  FanItem(label: t, child: Text(t), onSelect: () {}),
              ],
            ),
          ),
        ),
      ),
    ));
    final c = tester.getCenter(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    final f = tester.getCenter(find.text('F'));
    expect(f.dx, greaterThan(c.dx + 50)); // последний пункт — справа
    expect(f.dy, lessThan(c.dy));
    // 6 пунктов не налезают друг на друга
    final a = tester.getCenter(find.text('A')), b = tester.getCenter(find.text('B'));
    expect((a - b).distance, greaterThanOrEqualTo(50));
  });

  testWidgets('удержание и протягивание к пункту выбирает его при отпускании', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(app(log));
    final start = tester.getCenter(find.byIcon(Icons.add));
    final g = await tester.startGesture(start);
    await tester.pump();
    final c = tester.getCenter(find.text('C'));
    await g.moveTo(c);
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(log, ['C']);
    expect(find.text('C'), findsNothing);
  });
}
