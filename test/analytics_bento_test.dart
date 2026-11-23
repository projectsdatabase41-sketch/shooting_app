import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/theme/app_theme.dart';
import 'package:shooting_app/widgets/analytics_bento.dart';
import 'package:shooting_app/widgets/analytics_panel.dart';

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

  /// Динамика по выстрелам — так её собирает срез одной тренировки.
  List<AnalyticsDynamics> perShotDynamics(List<Shot> values) => [
        AnalyticsDynamics(title: 'Динамика выстрелов', subtitle: '', points: values, maxY: 10.9),
      ];

  Future<void> pumpBento(
    WidgetTester tester,
    double width, {
    List<Shot>? data,
    bool showMonths = true,
    List<AnalyticsDynamics>? dynamics,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnalyticsBento(
            shots: data ?? shots(),
            face: TargetFace.rifle10m,
            dynamics: dynamics,
            showMonths: showMonths,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('телефон 360 — без переполнений', (tester) async {
    await pumpBento(tester, 360);
    expect(tester.takeException(), isNull);
    expect(find.text('Итог'), findsOneWidget);
    expect(find.text('Габариты'), findsOneWidget);
  });

  testWidgets('десктоп 1024 — две колонки', (tester) async {
    await pumpBento(tester, 1024);
    expect(tester.takeException(), isNull);
    // В широкой раскладке карточки идут парами: первая карточка не шире
    // половины контейнера, иначе 2×2 развалилась в один столбец.
    final card = tester.getSize(find.text('Итог').first);
    expect(card.width, lessThan(1024));
  });

  testWidgets('без выстрелов не падает', (tester) async {
    await pumpBento(tester, 400, data: const []);
    expect(tester.takeException(), isNull);
    expect(find.text('—'), findsWidgets);
    // Отзыв 22.11, пункт 6: пустой график в «Итоге» читался как сломанный.
    expect(find.text('Мало данных'), findsOneWidget);
  });

  testWidgets('showMonths = false убирает «По месяцам» без переполнений', (tester) async {
    await pumpBento(tester, 360, showMonths: false);
    expect(tester.takeException(), isNull);
    // Отзыв 22.11, пункт 2: на срезе одной тренировки месяцы не нужны.
    expect(find.text('По месяцам'), findsNothing);
    expect(find.text('Габариты'), findsOneWidget);
  });

  testWidgets('нулевая дельта не рисуется чипом', (tester) async {
    final data = shots();
    // Ряд из двух точек с одинаковым результатом: дельта ровно ноль.
    final flat = [
      data.first.copyWith(id: 'a', score: 9.5),
      data.first.copyWith(id: 'b', score: 9.5),
    ];
    await pumpBento(tester, 360, data: flat, dynamics: perShotDynamics(flat));
    expect(tester.takeException(), isNull);
    // Отзыв 22.11, пункт 1: лишний «0» рядом с числом.
    expect(find.text('0'), findsNothing);
    expect(find.text('+0'), findsNothing);
  });

  testWidgets('одна точка динамики — подпись вместо пустого поля', (tester) async {
    final data = shots().take(1).toList();
    await pumpBento(tester, 360, data: data, dynamics: perShotDynamics(data));
    expect(tester.takeException(), isNull);
    // Отзыв 22.11, пункт 6: одна точка рисуется точкой по центру, а
    // подпись объясняет, что ряд ещё не набрался.
    expect(find.text('пока одна точка'), findsOneWidget);
  });
}
