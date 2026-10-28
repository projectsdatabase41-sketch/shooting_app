import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/selfie_light.dart';

void main() {
  testWidgets('подсветка включается сразу, но яркость нарастает плавно (~2,5 с)', (tester) async {
    final l = SelfieLightState();
    l.turnOn();
    expect(l.on, isTrue);
    expect(l.level, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(l.level, greaterThan(0.2));
    expect(l.level, lessThan(0.9));
    await tester.pump(const Duration(seconds: 3));
    expect(l.level, 1);
    l.turnOff();
    expect(l.on, isFalse);
    l.dispose();
  });

  testWidgets('свайп вверх увеличивает яркость, вправо — холоднее; выключенная подсветка жесты не перехватывает', (tester) async {
    final l = SelfieLightState()..brightness = 0.5;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SelfieLightGestures(light: l, child: const SizedBox.expand()))));
    await tester.drag(find.byType(SizedBox).first, const Offset(0, -120));
    expect(l.brightness, 0.5); // выключена — ничего не меняется
    l.turnOn();
    await tester.pump(const Duration(seconds: 3));
    await tester.drag(find.byType(SelfieLightGestures), const Offset(0, -120));
    expect(l.brightness, greaterThan(0.5));
    final w = l.warmth;
    await tester.drag(find.byType(SelfieLightGestures), const Offset(120, 0));
    expect(l.warmth, lessThan(w)); // слева направо — холоднее
    l.turnOff();
    l.dispose();
  });
}
