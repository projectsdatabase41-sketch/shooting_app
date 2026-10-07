import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/reaction_bar.dart';

void main() {
  test('порядок: недавние первыми, дубли убраны, все смайлики есть', () {
    final o = ReactionBar.ordered(['🎯', '👍']);
    expect(o.take(3), ['🎯', '👍', '❤️']);
    expect(o.toSet().length, o.length);
    expect(o.length, greaterThan(1500));
  });

  testWidgets('одна строка, прокрутка, раскрытие до 5 строк и выбор', (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ReactionBar(recent: const ['🎯'], onPick: (e) => picked = e),
        ),
      ),
    ));
    expect(find.text('🎯'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.text('🎯'));
    expect(picked, '🎯');

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    expect(tester.getSize(find.byType(GridView)).height, ReactionBar.cell * 5);

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
