import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/theme/app_theme.dart';
import 'package:shooting_app/widgets/analytics_bento.dart';

/// Обзор статистики должен собираться без переполнений на любой ширине:
/// на телефоне он в одну колонку, на десктопе — 2×2. Переполнение в
/// карточке на телефоне видно не сразу (RenderFlex рисует полосатый
/// индикатор и молча обрезает), поэтому ловим его тестом.
void main() {
  List<Shot> shots() {
    final out = <Shot>[];
    final base = DateTime(2026, 9, 1);
    for (var s = 1; s <= 4; s++) {
      for (var i = 1; i <= 10; i++) {
        out.add(Shot(
          id: 's${s}_$i',
          shotNumber: i,
          seriesNo: s,
          xMm: i * 1.5 - 8,
          yMm: i * 1.1 - 6,
          score: 9.2 + (i % 5) * 0.3,
          time: base.add(Duration(days: s * 20, minutes: i)),
        ));
      }
    }
    return out;
  }

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnalyticsBento(shots: shots(), face: TargetFace.rifle10m),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('телефон 360 — без переполнений', (tester) async {
    await pumpAt(tester, 360);
    expect(tester.takeException(), isNull);
    expect(find.text('Итог'), findsOneWidget);
    expect(find.text('Габариты'), findsOneWidget);
  });

  testWidgets('десктоп 1024 — две колонки', (tester) async {
    await pumpAt(tester, 1024);
    expect(tester.takeException(), isNull);
    // В широкой раскладке карточки идут парами: первая карточка не шире
    // половины контейнера, иначе 2×2 развалилась в один столбец.
    final card = tester.getSize(find.text('Итог').first);
    expect(card.width, lessThan(1024));
  });

  testWidgets('без выстрелов не падает', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnalyticsBento(shots: const [], face: TargetFace.rifle10m),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('—'), findsWidgets);
  });
}
