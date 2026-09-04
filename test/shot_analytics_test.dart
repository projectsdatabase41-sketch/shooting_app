import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/shot_analytics.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';

/// Мишень № 8: калибр 4.5 мм, значит радиус пробоины 2.25 мм — этот
/// порог отделяет "лёг в центр" от "есть направление сноса".
const face = TargetFace.rifle10m;

Shot shot({
  required double x,
  required double y,
  double score = 10.0,
  int series = 1,
  int number = 1,
}) {
  return Shot(
    id: 'x${x}y${y}n$number',
    shotNumber: number,
    seriesNo: series,
    xMm: x,
    yMm: y,
    score: score,
    time: DateTime(2026, 1, 1),
  );
}

void main() {
  group('Распределение по габаритам', () {
    test('габарит = целая часть результата, ключи есть все 10..0', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 0, score: 10.9),
        shot(x: 0, y: 1, score: 10.0),
        shot(x: 0, y: 2, score: 9.5),
        shot(x: 0, y: 3, score: 8.2),
        shot(x: 0, y: 4, score: 0.0),
      ], face);

      expect(a.ringCounts[10], 2, reason: '10.9 и 10.0 — обе десятки');
      expect(a.ringCounts[9], 1);
      expect(a.ringCounts[8], 1);
      expect(a.ringCounts[0], 1);
      expect(a.ringCounts[7], 0, reason: 'пустые габариты тоже присутствуют ключом');
      expect(a.ringCounts.length, 11);
      expect(a.tensCount, 2);
    });

    test('пустой набор — всё по нулям, без падений', () {
      final a = ShotAnalytics(const [], face);
      expect(a.isEmpty, isTrue);
      expect(a.average, 0);
      expect(a.total, 0);
      expect(a.meanOffsetMm, 0);
      expect(a.meanClock, isNull);
      expect(a.groupMeanRadiusMm, 0);
      expect(a.extremeSpreadMm, isNull);
      expect(a.directionalCount, 0);
      expect(a.seriesStats, isEmpty);
    });
  });

  group('СТП и кучность', () {
    // Крест: четыре выстрела на 10 мм от центра в четыре стороны.
    // Симметрично, поэтому СТП обязана быть ровно в центре.
    final cross = [
      shot(x: 0, y: 10, number: 1),
      shot(x: 10, y: 0, number: 2),
      shot(x: 0, y: -10, number: 3),
      shot(x: -10, y: 0, number: 4),
    ];

    test('симметричная группа — СТП в центре, направления нет', () {
      final a = ShotAnalytics(cross, face);
      expect(a.meanPoint.dx, closeTo(0, 1e-9));
      expect(a.meanPoint.dy, closeTo(0, 1e-9));
      expect(a.meanOffsetMm, closeTo(0, 1e-9));
      expect(a.meanClock, isNull, reason: 'смещение меньше радиуса пробоины');
    });

    test('средний разброс считается от СТП, а не от центра мишени', () {
      final a = ShotAnalytics(cross, face);
      expect(a.groupMeanRadiusMm, closeTo(10, 1e-9));
    });

    test('поперечник группы — расстояние между двумя самыми дальними', () {
      final a = ShotAnalytics(cross, face);
      expect(a.extremeSpreadMm, closeTo(20, 1e-9));
    });

    test('сдвинутая группа: кучность хорошая, но СТП ушла на 12 часов', () {
      // Три выстрела кучно, но все выше центра.
      final a = ShotAnalytics([
        shot(x: -1, y: 20, number: 1),
        shot(x: 0, y: 21, number: 2),
        shot(x: 1, y: 22, number: 3),
      ], face);

      expect(a.meanPoint.dx, closeTo(0, 1e-9));
      expect(a.meanPoint.dy, closeTo(21, 1e-9));
      expect(a.meanOffsetMm, closeTo(21, 1e-9));
      expect(a.meanClock, 12);
      expect(a.groupMeanRadiusMm, lessThan(2),
          reason: 'группа кучная, хотя и смещена — это разные показатели');
    });

    test('поперечник не считается на большой выборке (O(n²))', () {
      final many = [
        for (var i = 0; i <= ShotAnalytics.extremeSpreadLimit; i++)
          shot(x: i.toDouble(), y: 0, number: i),
      ];
      final a = ShotAnalytics(many, face);
      expect(many.length, greaterThan(ShotAnalytics.extremeSpreadLimit));
      expect(a.extremeSpreadMm, isNull);
    });
  });

  group('Разброс по часам', () {
    test('четыре стороны дают четыре корзины по одному', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 10, number: 1), // 12 часов -> индекс 0
        shot(x: 10, y: 0, number: 2), // 3 часа   -> индекс 3
        shot(x: 0, y: -10, number: 3), // 6 часов  -> индекс 6
        shot(x: -10, y: 0, number: 4), // 9 часов  -> индекс 9
      ], face);

      expect(a.clockCounts, [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0]);
      expect(a.directionalCount, 4);
    });

    test('выстрелы в центр в розу не попадают — у них нет направления', () {
      // Радиус 1.41 мм < радиуса пробоины 2.25 мм.
      final a = ShotAnalytics([shot(x: 1, y: 1)], face);
      expect(a.directionalCount, 0);
      expect(a.clockCounts.every((c) => c == 0), isTrue);
      expect(a.count, 1, reason: 'в общем счёте выстрел при этом остаётся');
    });
  });

  group('Статистика по сериям', () {
    test('группировка по seriesNo, порядок по возрастанию', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 1, score: 10.0, series: 2, number: 3),
        shot(x: 0, y: 1, score: 9.0, series: 1, number: 1),
        shot(x: 0, y: 1, score: 10.0, series: 1, number: 2),
      ], face);

      expect(a.seriesStats.map((s) => s.seriesNo).toList(), [1, 2]);
      expect(a.seriesStats.first.count, 2);
      expect(a.seriesStats.first.total, closeTo(19, 1e-9));
      expect(a.seriesStats.first.average, closeTo(9.5, 1e-9));
      expect(a.seriesStats.last.average, closeTo(10, 1e-9));
    });
  });

  group('Разбивка десятки по десятым', () {
    test('все выстрелы в десятке — allInTen и раскладка по десятым', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 0, score: 10.9),
        shot(x: 0, y: 0.2, score: 10.9),
        shot(x: 0, y: 0.5, score: 10.5),
        shot(x: 0, y: 1, score: 10.0),
      ], face);

      expect(a.allInTen, isTrue);
      expect(a.tenDecimalCounts[9], 2, reason: '10.9 → корзина 9');
      expect(a.tenDecimalCounts[5], 1);
      expect(a.tenDecimalCounts[0], 1, reason: '10.0 → корзина 0');
      expect(a.tenDecimalCounts.length, 10);
    });

    test('хотя бы одна девятка — раскладку не показываем', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 0, score: 10.9),
        shot(x: 0, y: 5, score: 9.8),
      ], face);
      expect(a.allInTen, isFalse);
    });

    test('пустой срез не считается «всё в десятке»', () {
      expect(ShotAnalytics(const [], face).allInTen, isFalse);
    });
  });

  group('Сумма целыми', () {
    test('десятые отбрасываются у каждого выстрела, а не у суммы', () {
      final a = ShotAnalytics([
        shot(x: 0, y: 0, score: 10.9),
        shot(x: 0, y: 1, score: 10.9),
        shot(x: 0, y: 2, score: 9.9),
      ], face);

      expect(a.total, closeTo(31.7, 1e-9));
      // Округли сумму — вышло бы 32. Правило соревнований другое:
      // каждый выстрел засчитывается целым габаритом, десятые
      // отбрасываются у каждого отдельно: 10 + 10 + 9.
      expect(a.totalWhole, 29);
    });
  });

  group('CEP — радиус, внутрь которого попадает доля выстрелов', () {
    test('порядковая статистика по расстояниям от СТП', () {
      // СТП в нуле: выстрелы симметричны. Расстояния 1,2,3,4.
      final a = ShotAnalytics([
        shot(x: 1, y: 0, number: 1),
        shot(x: -2, y: 0, number: 2),
        shot(x: 0, y: 3, number: 3),
        shot(x: 0, y: -4, number: 4),
      ], face);

      expect(a.meanPoint.dx, closeTo(-0.25, 1e-9));
      // Считаем от фактической СТП, поэтому проверяем не точные числа,
      // а порядок: половина попаданий ближе, чем девять десятых.
      final half = a.cepRadiusMm(0.5)!;
      final most = a.cepRadiusMm(0.9)!;
      expect(half, lessThan(most));
      expect(most, lessThanOrEqualTo(a.extremeSpreadMm!));
    });

    test('на трёх выстрелах не считаем — это шум', () {
      final a = ShotAnalytics([
        shot(x: 1, y: 0, number: 1),
        shot(x: 0, y: 1, number: 2),
        shot(x: -1, y: 0, number: 3),
      ], face);
      expect(a.cepRadiusMm(0.5), isNull);
    });
  });

  group('Окружность максимального рассеивания', () {
    test('строится на паре самых далёких пробоин', () {
      final a = ShotAnalytics([
        shot(x: -10, y: 0, number: 1),
        shot(x: 0, y: 1, number: 2),
        shot(x: 10, y: 0, number: 3),
      ], face);

      final pair = a.extremePair!;
      expect({pair.$1.shotNumber, pair.$2.shotNumber}, {1, 3});
      expect(a.extremeSpreadMm, closeTo(20, 1e-9));
      // Центр — середина отрезка, а не СТП: СТП здесь ушла бы вверх
      // из-за второго выстрела.
      expect(a.spreadCircleCenterMm!.dx, closeTo(0, 1e-9));
      expect(a.spreadCircleCenterMm!.dy, closeTo(0, 1e-9));
    });
  });

  group('Направление смещения словами', () {
    test('восемь румбов, Y вверх', () {
      expect(directionName(const Offset(0, 5)), 'вверх');
      expect(directionName(const Offset(5, 5)), 'вверх-вправо');
      expect(directionName(const Offset(5, 0)), 'вправо');
      expect(directionName(const Offset(5, -5)), 'вниз-вправо');
      expect(directionName(const Offset(0, -5)), 'вниз');
      expect(directionName(const Offset(-5, -5)), 'вниз-влево');
      expect(directionName(const Offset(-5, 0)), 'влево');
      expect(directionName(const Offset(-5, 5)), 'вверх-влево');
    });

    test('около нуля направления нет', () {
      expect(directionName(Offset.zero), isNull);
      expect(directionName(const Offset(0.01, 0.01)), isNull);
    });
  });

  group('niceMax — округление верха шкалы графика', () {
    test('сумма тренировки 109 округляется до 150 (шаг 30)', () {
      expect(niceMax(109), 150);
    });

    test('мелкие и нулевые значения не ломают шкалу', () {
      expect(niceMax(0), 10);
      expect(niceMax(-5), 10);
      expect(niceMax(9.5), 10);
    });

    test('точное попадание в круглое число не поднимает шкалу выше', () {
      expect(niceMax(100), 100);
      expect(niceMax(500), 500);
    });
  });
}
