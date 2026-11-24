import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/widgets/sius_panel.dart';

/// Панель «как SIUS» (запрос владельца 24.11): суммы серий, счёт
/// центральных по порогам, «последние 5» и MPI, отсутствие переполнения
/// в узкой (640×360) и широкой (1280×800) раскладке.
SiusShotRow _row(int no, int series, double score, {Offset? p, bool sight = false}) =>
    SiusShotRow(
      number: no,
      series: series,
      score: score,
      point: p ?? Offset.zero,
      sighting: sight,
    );

Shot _shot(double score) => Shot(
      id: 's$score',
      shotNumber: 1,
      seriesNo: 1,
      xMm: 0,
      yMm: 0,
      score: score,
      time: DateTime(2026),
    );

void main() {
  group('Пороги «центральных» выстрелов', () {
    // Таблица ориентировочная, уточняется у владельца / по ISSF (24.11) —
    // проверяем, что она остаётся одной таблицей в scoring.dart.
    test('rifle_50m — 10.3, rifle_10m — 10.5, pistol_10m — 10.4', () {
      expect(centralThresholdFor(TargetFace.rifle50m), closeTo(10.3, 1e-9));
      expect(centralThresholdFor(TargetFace.rifle10m), closeTo(10.5, 1e-9));
      expect(centralThresholdFor(TargetFace.pistol10m), closeTo(10.4, 1e-9));
    });

    test('остальные мишени — прикидка 10.4', () {
      expect(centralThresholdFor(TargetFace.pistol25m), closeTo(10.4, 1e-9));
      expect(centralThresholdFor(TargetFace.rifle300m), closeTo(10.4, 1e-9));
    });

    test('порог можно переопределить у самой мишени', () {
      const face = TargetFace(
        code: 'test_face',
        name: 'тестовая',
        distanceM: 10,
        caliberMm: 4.5,
        bullseyeDiameterMm: 30.5,
        ringDiametersMm: [0.5, 5.5, 10.5],
        centralTenThreshold: 9.3,
      );
      expect(centralThresholdFor(face), closeTo(9.3, 1e-9));
    });
  });

  group('Счёт центральных', () {
    test('на № 7 (порог 10.3): границы и ниже порога', () {
      // 10.3 — центральный (граница принадлежит более высокому значению),
      // 10.2 и ниже — нет.
      final shots = [_shot(10.9), _shot(10.3), _shot(10.2), _shot(9.9), _shot(10.3)];
      expect(countCentral(shots, TargetFace.rifle50m), 3);
      expect(countCentralScores([10.9, 10.3, 10.2, 9.9, 10.3], TargetFace.rifle50m), 3);
    });

    test('на № 8 (порог 10.5) 10.4 не считается центральным', () {
      expect(countCentralScores([10.4, 10.5, 10.9], TargetFace.rifle10m), 2);
    });

    test('пустой список — ноль', () {
      expect(countCentral(const [], TargetFace.rifle50m), 0);
    });
  });

  group('SiusPanel', () {
    Future<void> pumpPanel(
      WidgetTester tester,
      Size size,
      SiusPanel panel,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox.fromSize(size: size, child: panel))),
      );
      await tester.pump();
    }

    testWidgets('суммы завершённых серий и «Σ … — …» с центральными', (tester) async {
      final rows = [
        // Серия 1: девять по 10.4 и один 10.6 — сумма 104.2, одна «центральная»
        // (10.6 ≥ 10.5 — порог № 8).
        for (var i = 0; i < 9; i++) _row(i + 1, 1, 10.4),
        _row(10, 1, 10.6),
        // Серия 2 началась, но не завершена: в суммы не попадает,
        // но 10.5 на № 8 — центральный.
        _row(11, 2, 10.5),
      ];
      await pumpPanel(
        tester,
        const Size(1280, 800),
        SiusPanel(
          face: TargetFace.rifle10m,
          shots: rows,
          title: '№ 8',
          seriesShots: const [10, 10],
          seriesLabel: 'Серия 2 из 2',
        ),
      );
      expect(find.textContaining('S1 104.2'), findsOneWidget);
      // Незавершённая серия не суммируется.
      expect(find.textContaining('S2'), findsNothing);
      // Итог: сумма всей тренировки, после тире — число центральных.
      expect(find.text('Σ 114.7 — 2'), findsOneWidget);
      // Последний выстрел крупно.
      expect(find.text('10.5'), findsWidgets);
    });

    testWidgets('разделитель серии внутри списка', (tester) async {
      final rows = [
        _row(1, 1, 10.0),
        _row(2, 1, 10.0),
        _row(3, 2, 9.9),
      ];
      await pumpPanel(
        tester,
        const Size(640, 360),
        SiusPanel(face: TargetFace.rifle10m, shots: rows, title: '№ 8'),
      );
      expect(find.text('Серия 1'), findsOneWidget);
      expect(find.text('Серия 2'), findsOneWidget);
      // Метка закрытия серии «S10»-вида: в серии по 2 выстрела.
      expect(find.text('S2'), findsOneWidget);
    });

    testWidgets('пристрелка: «последние 5» и MPI вместо сумм и Σ', (tester) async {
      final rows = [
        _row(1, 1, 10.4, p: const Offset(2, 1), sight: true),
        _row(2, 1, 10.4, p: const Offset(0, -1), sight: true),
        _row(3, 1, 10.4, p: const Offset(-2, 3), sight: true),
        _row(4, 1, 10.4, p: const Offset(1, 0), sight: true),
        _row(5, 1, 10.4, p: const Offset(1, -4), sight: true),
      ];
      // mean x = (2+0−2+1+1)/5 = 0.4 → «→0.4»; mean y = (1−1+3+0−4)/5 =
      // −0.2 → «↓0.2»; y вверх, поэтому отрицательный dy — «вниз».
      await pumpPanel(
        tester,
        const Size(1280, 800),
        SiusPanel(
          face: TargetFace.rifle50m,
          shots: rows,
          title: 'Пристрелка',
          lastFiveMode: true,
        ),
      );
      expect(find.textContaining('Последние 5: 52.0'), findsOneWidget);
      expect(find.textContaining('MPI (5): →0.4 ↓0.2'), findsOneWidget);
      // Без суммы и общего результата (владелец 24.11).
      expect(find.textContaining('Σ'), findsNothing);
    });

    testWidgets('пристрелка с менее чем пятью выстрелами', (tester) async {
      final rows = [
        _row(1, 1, 10.3, p: const Offset(-1, 2), sight: true),
        _row(2, 1, 10.3, p: const Offset(-1, 2), sight: true),
      ];
      await pumpPanel(
        tester,
        const Size(640, 360),
        SiusPanel(
          face: TargetFace.rifle50m,
          shots: rows,
          title: 'Пристрелка',
          lastFiveMode: true,
        ),
      );
      expect(find.textContaining('Последние 2: 20.6'), findsOneWidget);
      expect(find.textContaining('MPI (2): ←1.0 ↑2.0'), findsOneWidget);
    });

    testWidgets('нет переполнения на 640×360 и 1280×800, длинная серия', (tester) async {
      final rows = [
        for (var i = 0; i < 24; i++) _row(i + 1, (i ~/ 10) + 1, 10.1),
      ];
      for (final size in [const Size(640, 360), const Size(1280, 800)]) {
        await pumpPanel(
          tester,
          size,
          SiusPanel(
            face: TargetFace.rifle10m,
            shots: rows,
            title: '№ 8, пневматическая винтовка 10 м — очень длинное название',
            seriesShots: const [10, 10, 10],
            seriesLabel: 'Серия 3 из 3',
            timeText: '12:30',
            countdownText: '1:45',
          ),
        );
        expect(tester.takeException(), isNull, reason: 'размер ${size.width}×${size.height}');
      }
    });
  });
}
