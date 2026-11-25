import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/stance_icon.dart';

void main() {
  testWidgets('ассеты изготовок вшиты в приложение', (tester) async {
    for (final name in [
      'standing_rifle.png',
      'standing_pistol.png',
      'kneeling_rifle.png',
      'prone_rifle.png',
    ]) {
      final data = await rootBundle.load('assets/stances/$name');
      expect(data.lengthInBytes, greaterThan(1000), reason: name);
    }
  });
  // Все комбинации изготовка × оружие в двух размерах: pumpWidget не роняет
  // исключений, виджет находится и рисуется (paint вызывается в тестовой
  // среде при отрисовке кадра).
  for (final stance in StanceKind.values) {
    for (final weapon in WeaponKind.values) {
      for (final size in [24.0, 48.0]) {
        testWidgets(
            'StanceIcon $stance/$weapon при size $size рисуется без исключений',
            (tester) async {
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Center(
                child: StanceIcon(
                  stance: stance,
                  weapon: weapon,
                  color: const Color(0xFF112233),
                  size: size,
                  semanticLabel: 'Изготовка',
                ),
              ),
            ),
          ));
          expect(tester.takeException(), isNull);
          expect(find.byType(StanceIcon), findsOneWidget);
        });
      }
    }
  }

  testWidgets('size 0 не падает — рисовать нечего, виджет существует',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StanceIcon(
          stance: StanceKind.allThree,
          weapon: WeaponKind.rifle,
          color: Colors.teal,
          size: 0,
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(StanceIcon), findsOneWidget);
  });
}
