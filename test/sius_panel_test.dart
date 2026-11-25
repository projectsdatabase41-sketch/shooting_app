import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/widgets/sius_panel.dart';

/// Панель «как SIUS» (запрос владельца 24.11): суммы серий, счёт
/// центральных по геометрии (евклидов радиус точки попадания), «последние 5»
/// и MPI, отсутствие переполнения в узкой (640×360) и широкой (1280×800)
/// раскладке.
SiusShotRow _row(int no, int series, double score, {Offset? p, bool sight = false}) =>
    SiusShotRow(
      number: no,
      series: series,
      score: score,
      point: p ?? Offset.zero,
      sighting: sight,
    );

Shot _shot(double xMm, double yMm, double score) => Shot(
      id: 's$score-$xMm',
      shotNumber: 1,
      seriesNo: 1,
      xMm: xMm,
      yMm: yMm,
      score: score,
      time: DateTime(2026),
    );

void main() {
  group('Границы центрального выстрела по евклидову радиусу (владелец 24.11)', () {
    test('rifle_10m (№ 8): «полное выбивание точки», r ≤ (4.50 − 0.50)/2 = 2.00 мм',
        () {
      // Чуть меньше границы — центральный; ровно на границе — центральный
      // (граница принадлежит более высокому достоинству); чуть больше — нет.
      expect(isInnerTen(1.999, 0.0, TargetFace.rifle10m), isTrue);
      expect(isInnerTen(0.0, 2.0, TargetFace.rifle10m), isTrue);
      expect(isInnerTen(2.001, 0.0, TargetFace.rifle10m), isFalse);
      // Диагональ: r = √(1.4² + 1.4²) ≈ 1.98 — центральный; √(1.5²+1.5²) ≈ 2.12 — нет.
      expect(isInnerTen(1.4, 1.4, TargetFace.rifle10m), isTrue);
      expect(isInnerTen(1.5, 1.5, TargetFace.rifle10m), isFalse);
      // Порог 2.00 мм — это граница десятых 10.1/10.2, а НЕ 10.5: r = 2.0
      // даёт десятичный 10.2, чуть больше — уже 10.1 (не центральный).
      // (Замечание: при десятичном счёте выстрел 10.4 лежит в r около
      // 1.25–1.5 мм, т.е. внутри точки — «10.4 не центральный» было верно
      // для СТАРОГО порога 10.5, по геометрии выбирается точка целиком.)
      expect(scoreForPoint(2.0, 0.0, TargetFace.rifle10m), closeTo(10.2, 1e-9));
      expect(scoreForPoint(2.1, 0.0, TargetFace.rifle10m), closeTo(10.1, 1e-9));
      expect(isInnerTen(2.1, 0.0, TargetFace.rifle10m), isFalse);
    });

    test('rifle_50m (№ 7): «касание», r ≤ (5.00 + 5.60)/2 = 5.30 мм', () {
      expect(isInnerTen(5.29, 0.0, TargetFace.rifle50m), isTrue);
      expect(isInnerTen(5.3, 0.0, TargetFace.rifle50m), isTrue);
      expect(isInnerTen(5.31, 0.0, TargetFace.rifle50m), isFalse);
      // Диагональ: √(4² + 3²) = 5.0 — внутри; √(4.5² + 3²) ≈ 5.41 — снаружи.
      expect(isInnerTen(4.0, 3.0, TargetFace.rifle50m), isTrue);
      expect(isInnerTen(4.5, 3.0, TargetFace.rifle50m), isFalse);
    });

    test('pistol_10m (№ 9): «касание», r ≤ (5.00 + 4.50)/2 = 4.75 мм', () {
      expect(isInnerTen(4.749, 0.0, TargetFace.pistol10m), isTrue);
      expect(isInnerTen(4.75, 0.0, TargetFace.pistol10m), isTrue);
      expect(isInnerTen(4.751, 0.0, TargetFace.pistol10m), isFalse);
      // Диагональ: √(3² + 3²) ≈ 4.24 — внутри; √(3.4² + 3.4²) ≈ 4.81 — снаружи.
      expect(isInnerTen(3.0, 3.0, TargetFace.pistol10m), isTrue);
      expect(isInnerTen(3.4, 3.4, TargetFace.pistol10m), isFalse);
    });

    test('мишени вне таблицы — центральные не считаются', () {
      expect(innerTenLimitMm(TargetFace.moving50m), isNull);
      expect(isInnerTen(0.0, 0.0, TargetFace.moving50m), isFalse);
      expect(countInnerTenPoints(const [(0.0, 0.0)], TargetFace.moving50m), 0);
    });

    test('мишени, добавленные с пометкой «уточнить у владельца/по ISSF»', () {
      // № 4, пистолет 25/50 м: (25.0 + 5.60)/2 = 15.30 мм.
      expect(innerTenLimitMm(TargetFace.pistol25m), closeTo(15.30, 1e-9));
      expect(isInnerTen(15.29, 0.0, TargetFace.pistol25m), isTrue);
      expect(isInnerTen(15.31, 0.0, TargetFace.pistol25m), isFalse);
      // 300 м винтовка: (50.0 + 7.62)/2 = 28.81 мм.
      expect(innerTenLimitMm(TargetFace.rifle300m), closeTo(28.81, 1e-9));
      expect(isInnerTen(28.80, 0.0, TargetFace.rifle300m), isTrue);
      expect(isInnerTen(28.82, 0.0, TargetFace.rifle300m), isFalse);
    });

    test('лук: старая форма isInnerTen(расстояние, мишень) сохранена', () {
      // Лук целочисленный, X — по краю древка, ближайшему к центру: считаем
      // по существующему полю innerTenRadiusMm, а формулу правила проверяем
      // на заведомо далёкой точке (а не на «почти границе», где допуск
      // древка делает результат неоднозначным).
      expect(isInnerTen(0.0, TargetFace.archery122), isTrue);
      expect(isInnerTen(60.0, TargetFace.archery122), isFalse);
    });
  });

  group('Счёт центральных (геометрия точек)', () {
    test('на № 7 (граница 5.30 мм): геометрические точки, не десятичный балл', () {
      // r = 0 → 10.9, r = 5.0 → 10.3, r = 6.0 → 10.2, r = 5.29 → 10.3,
      // r = 5.31 → 10.3 (тот же десятичный балл, что у 5.29, но точка
      // дальше границы 5.30 — НЕ центральный).
      final shots = [
        _shot(0, 0, 10.9),
        _shot(5.0, 0, 10.3),
        _shot(6.0, 0, 10.2),
        _shot(5.29, 0, 10.3),
        _shot(5.31, 0, 10.3),
      ];
      expect(countInnerTen(shots, TargetFace.rifle50m), 3);
      expect(countInnerTenPoints(
          [(0.0, 0.0), (5.0, 0.0), (6.0, 0.0), (5.29, 0.0), (5.31, 0.0)],
          TargetFace.rifle50m),
          3);
    });

    test('на № 8 (граница 2.00 мм): 10.1 (r = 2.1) не центральный', () {
      final shots = [
        _shot(0.0, 0.0, 10.9),
        _shot(2.1, 0.0, 10.1),
        _shot(2.0, 0.0, 10.2),
      ];
      expect(countInnerTen(shots, TargetFace.rifle10m), 2);
    });

    test('пустой список — ноль', () {
      expect(countInnerTen(const [], TargetFace.rifle50m), 0);
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
        // Серия 1: девять выстрелов 10.1 (r = 2.1 — за границей 2.00 № 8,
        // не центральные) и один 10.2 (r = 2.00 — ровно граница, центральный):
        // сумма 101.1, одна «центральная».
        for (var i = 0; i < 9; i++) _row(i + 1, 1, 10.1, p: const Offset(2.1, 0)),
        _row(10, 1, 10.2, p: const Offset(-2.0, 0)),
        // Серия 2 началась, но не завершена: в суммы не попадает;
        // 10.2 при r = 1.9 — центральный.
        _row(11, 2, 10.2, p: const Offset(0, 1.9)),
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
      expect(find.textContaining('S1 101.1'), findsOneWidget);
      // Незавершённая серия не суммируется.
      expect(find.textContaining('S2'), findsNothing);
      // Итог: сумма всей тренировки (111.3), после тире — число центральных (2)
      // по евклидову радиусу точек, не по десятичному баллу.
      expect(find.text('Σ 111.3 — 2'), findsOneWidget);
      // Последний выстрел крупно.
      expect(find.text('10.2'), findsWidgets);
    });

    testWidgets('разделитель серии внутри списка', (tester) async {
      final rows = [
        _row(1, 1, 10.0, p: const Offset(2.3, 0)),
        _row(2, 1, 10.0, p: const Offset(0, 2.3)),
        _row(3, 2, 9.9, p: const Offset(4.0, 0)),
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
        for (var i = 0; i < 24; i++)
          _row(i + 1, (i ~/ 10) + 1, 10.1, p: const Offset(2.3, 0)),
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

  // Отзыв f6cc163e (фото SIUS): у каждой строки — стрелка смещения от
  // центра, в «мёртвой зоне» — точка.
  test('стрелка смещения: восемь направлений и мёртвая зона у центра', () {
    expect(siusDirectionArrow(const Offset(5, 0), deadZoneMm: 0.6), '→');
    expect(siusDirectionArrow(const Offset(4, 4), deadZoneMm: 0.6), '↗');
    expect(siusDirectionArrow(const Offset(0, 5), deadZoneMm: 0.6), '↑');
    expect(siusDirectionArrow(const Offset(-4, 4), deadZoneMm: 0.6), '↖');
    expect(siusDirectionArrow(const Offset(-5, 0), deadZoneMm: 0.6), '←');
    expect(siusDirectionArrow(const Offset(-4, -4), deadZoneMm: 0.6), '↙');
    expect(siusDirectionArrow(const Offset(0, -5), deadZoneMm: 0.6), '↓');
    expect(siusDirectionArrow(const Offset(4, -4), deadZoneMm: 0.6), '↘');
    expect(siusDirectionArrow(const Offset(0.2, -0.1), deadZoneMm: 0.6), '·');
  });
}
