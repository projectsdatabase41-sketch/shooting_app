import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/target_face.dart';

void main() {
  // Модель очков переработана 2026-09-02 по ТЗ пользователя
  // («Техническое задание для алгоритма расчета очков, ISSF Мишень №7»):
  // целая часть — по официальным границам колец, десятая доля — по
  // ШИРИНЕ КОЛЬЦА (шаг = ширина/10), а не по радиусу пули, как было в
  // предыдущей модели. Подробности и разбор двух неточностей в тексте
  // ТЗ — в комментарии к lib/logic/scoring.dart.

  group('Мишень № 7 (винтовка 50 м) — контрольная таблица ТЗ', () {
    const face = TargetFace.rifle50m; // кольцо 10 = 5.2мм, пуля 2.8мм, шаг 0.8мм

    test('константы мишени совпадают с ТЗ', () {
      expect(face.ringRadiiMm[0], closeTo(5.2, 1e-9), reason: 'радиус десятки');
      expect(face.ringRadiiMm[1], closeTo(13.2, 1e-9), reason: 'радиус девятки');
      expect(face.caliberRadiusMm, closeTo(2.8, 1e-9), reason: 'радиус пули 5.6/2');
      expect(face.ringWidthMm, closeTo(8.0, 1e-9), reason: '13.2 − 5.2');
      expect(face.decimalStepMm, closeTo(0.8, 1e-9), reason: '8.0 / 10');
    });

    // Таблица ветвления из ТЗ. Пороги в ней — расстояние от центра
    // МИШЕНИ до центра ПРОБОИНЫ (вычет радиуса пули в этих числах уже
    // учтён: 10.0 стоит на 8.0 = 5.2 + 2.8, а 9.0 на 16.0 = 13.2 + 2.8).
    // Список пар, а не Map: `double` переопределяет `==`, поэтому
    // ключом константной карты быть не может (const_map_key_not_
    // primitive_equality). Записи (records) этого ограничения не имеют.
    const branchTable = [
      (0.0, 10.9),
      (0.8, 10.9),
      (1.6, 10.8),
      (2.4, 10.7),
      (3.2, 10.6),
      (4.0, 10.5),
      (4.8, 10.4),
      (5.6, 10.3),
      (6.4, 10.2),
      (7.2, 10.1),
      (8.0, 10.0),
      (16.0, 9.0),
    ];

    for (final row in branchTable) {
      final distance = row.$1;
      final expected = row.$2;
      test('расстояние $distance мм -> $expected', () {
        expect(scoreForRadius(distance, face), closeTo(expected, 1e-9));
      });
    }

    test('граница принадлежит более высокому габариту, сразу за ней — ниже', () {
      expect(scoreForRadius(8.0, face), closeTo(10.0, 1e-9));
      expect(scoreForRadius(8.01, face), closeTo(9.9, 1e-9));
      expect(scoreForRadius(16.0, face), closeTo(9.0, 1e-9));
      expect(scoreForRadius(16.01, face), closeTo(8.9, 1e-9));
    });

    test('шаг 0.8 мм работает во всех зонах, не только в десятке', () {
      // Между кольцами 8 и 9 расстояние тоже 8.0 мм (21.2 − 13.2).
      expect(scoreForRadius(24.0, face), closeTo(8.0, 1e-9));
      expect(scoreForRadius(24.0 - 0.8, face), closeTo(8.1, 1e-9));
      expect(scoreForRadius(24.0 - 7.2, face), closeTo(8.9, 1e-9));
    });

    test('за внешним кольцом — 0', () {
      final beyond = face.ringRadiiMm.last + face.caliberRadiusMm + 1;
      expect(scoreForRadius(beyond, face), 0.0);
    });

    test('пороги ТЗ НЕ трактуются как R_calc (иначе калибр вычелся бы дважды)', () {
      // Если бы 0.8 в таблице означало R_calc (уже с вычтенным радиусом
      // пули), результат был бы 10.9. Он равен 10.5 — и это правильно:
      // R_calc = 0.8 соответствует расстоянию 3.6 мм от центра.
      expect(scoreForEffectiveRadius(0.8, face), closeTo(10.5, 1e-9));
      expect(scoreForRadius(3.6, face), closeTo(10.5, 1e-9));
    });

    test('замкнутая формула из ТЗ не применяется — она противоречит таблице', () {
      // 10.9 − trunc(R_calc/0.8, 1) при R_calc = 1.0 дало бы 9.7,
      // тогда как таблица в той же точке (расстояние 3.8 мм) даёт 10.5.
      expect(scoreForEffectiveRadius(1.0, face), closeTo(10.5, 1e-9));
    });
  });

  group('Мишень № 8 (винтовка 10 м) — модель обобщена на все мишени', () {
    const face = TargetFace.rifle10m; // кольцо 10 = 0.25мм, пуля 2.25мм, шаг 0.25мм

    test('у каждой мишени свой шаг десятой, а не зашитые 0.8 мм от № 7', () {
      expect(face.decimalStepMm, closeTo(0.25, 1e-9));
      expect(TargetFace.pistol10m.decimalStepMm, closeTo(0.8, 1e-9));
      expect(TargetFace.rifle50m.decimalStepMm, closeTo(0.8, 1e-9));
      expect(TargetFace.pistol25m.decimalStepMm, closeTo(2.5, 1e-9));
    });

    test('D=0 (пробоина точно по центру мишени) -> 10.9', () {
      expect(scoreForEffectiveRadius(-face.caliberRadiusMm, face), 10.9);
    });

    test('eff=0 (край пробоины точно в центре, но НЕ D=0) -> 10.1', () {
      expect(scoreForEffectiveRadius(0, face), closeTo(10.1, 1e-9));
    });

    test('граница кольца 10 (официально 0.25мм) -> 10.0', () {
      expect(scoreForEffectiveRadius(face.ringRadiiMm.first, face), closeTo(10.0, 1e-9));
    });

    test('eff=4.25мм -> 8.4', () {
      expect(scoreForEffectiveRadius(4.25, face), closeTo(8.4, 1e-9));
    });

    test('за пределами кольца 1 (официально 22.75мм) -> 0', () {
      expect(scoreForEffectiveRadius(face.ringRadiiMm.last + 1, face), 0.0);
    });

    test('глубоко отрицательный эффективный радиус -> 10.9, не уходит выше', () {
      expect(scoreForEffectiveRadius(-100, face), 10.9);
    });

    test('монотонность: результат не возрастает с ростом расстояния', () {
      double prev = 20;
      for (double d = 0; d <= 30; d += 0.37) {
        final score = scoreForEffectiveRadius(d, face);
        expect(score, lessThanOrEqualTo(prev + 1e-9));
        prev = score;
      }
    });

    test('один шаг десятой по радиусу меняет результат ровно на 0.1', () {
      // Важно для степпера "Результат" (A.6): новая модель линейна по
      // радиусу, поэтому шаг степпера теперь точный, а не приближённый.
      const start = 6.0; // мм от центра, заведомо внутри разметки
      final a = scoreForRadius(start, face);
      final b = scoreForRadius(start + face.decimalStepMm, face);
      expect(a - b, closeTo(0.1, 1e-9));
    });
  });

  group('scoreForRadius — вычитание радиуса пули (inward gauging)', () {
    const face = TargetFace.rifle10m;

    test('расстояние = 0 (истинный центр мишени) -> 10.9', () {
      expect(scoreForRadius(0, face), 10.9);
    });

    test('расстояние = радиус пробоины -> 10.1', () {
      expect(scoreForRadius(2.25, face), closeTo(10.1, 1e-9));
    });

    test('расстояние 1мм от центра -> 10.6', () {
      expect(scoreForRadius(1.0, face), closeTo(10.6, 1e-9));
    });

    test('калибр вычитается, а не прибавляется — ближе к центру не хуже', () {
      expect(scoreForRadius(5.0, face), lessThan(scoreForRadius(1.0, face)));
    });
  });

  group('Справочник мишеней — у каждой свои константы', () {
    test('шаг десятой, калибр и границы колец различаются по мишеням', () {
      const expected = {
        TargetFace.rifle10m: [0.25, 2.75, 2.25, 0.25], // R10, R9, R пули, шаг
        TargetFace.pistol10m: [5.75, 13.75, 2.25, 0.8],
        TargetFace.rifle50m: [5.2, 13.2, 2.8, 0.8],
        TargetFace.pistol25m: [25.0, 50.0, 2.8, 2.5],
      };
      for (final e in expected.entries) {
        final face = e.key;
        expect(face.ringRadiiMm[0], closeTo(e.value[0], 1e-9), reason: '${face.name}: R10');
        expect(face.ringRadiiMm[1], closeTo(e.value[1], 1e-9), reason: '${face.name}: R9');
        expect(face.caliberRadiusMm, closeTo(e.value[2], 1e-9), reason: '${face.name}: радиус пули');
        expect(face.decimalStepMm, closeTo(e.value[3], 1e-9), reason: '${face.name}: шаг десятой');
      }
    });

    test('10.0 стоит на «граница десятки + радиус пули» у каждой мишени', () {
      for (final face in TargetFace.all) {
        final boundary = face.ringRadiiMm[0] + face.caliberRadiusMm;
        expect(scoreForRadius(boundary, face), closeTo(10.0, 1e-9), reason: face.name);
        // На один шаг ближе к центру — уже 10.1.
        expect(scoreForRadius(boundary - face.decimalStepMm, face), closeTo(10.1, 1e-9),
            reason: face.name);
      }
    });

    test('10.9 достижима на каждой мишени и требует своей точности', () {
      const expectedRadius = {
        TargetFace.rifle10m: 0.25,
        TargetFace.pistol10m: 0.8,
        TargetFace.rifle50m: 0.8,
        TargetFace.pistol25m: 5.3,
      };
      for (final e in expectedRadius.entries) {
        expect(scoreForRadius(0, e.key), closeTo(10.9, 1e-9), reason: '${e.key.name}: центр');
        expect(scoreForRadius(e.value, e.key), closeTo(10.9, 1e-9), reason: '${e.key.name}: порог');
        expect(scoreForRadius(e.value + 0.01, e.key), closeTo(10.8, 1e-9),
            reason: '${e.key.name}: сразу за порогом');
      }
    });
  });

  group('Метод измерения — параметр мишени, а не константа алгоритма', () {
    test('все четыре мишени считаются «вовнутрь»', () {
      for (final face in TargetFace.all) {
        expect(face.gauging, GaugingMethod.inward, reason: face.name);
        expect(face.gaugingOffsetMm, closeTo(-face.caliberRadiusMm, 1e-9), reason: face.name);
      }
    });

    // Копия № 9 со схемой «наружу» — только для проверки, что алгоритм
    // умеет обе. В справочнике так не стоит: см. ниже, почему.
    const outwardPistol = TargetFace(
      code: 'pistol_10m_outward_test',
      name: '№ 9 (тестовая копия, измерение наружу)',
      distanceM: 10,
      caliberMm: 4.5,
      bullseyeDiameterMm: 59.5,
      blankSizeMm: 170,
      ringDiametersMm: [11.5, 27.5, 43.5, 59.5, 75.5, 91.5, 107.5, 123.5, 139.5, 155.5],
      gauging: GaugingMethod.outward,
    );

    test('«наружу» меняет знак поправки на калибр', () {
      expect(outwardPistol.gaugingOffsetMm, closeTo(2.25, 1e-9));
      expect(TargetFace.pistol10m.gaugingOffsetMm, closeTo(-2.25, 1e-9));
    });

    test('«наружу» делает 10.9 недостижимой — потолок 10.4', () {
      // Главный довод против «наружу» для пистолета: минимальный R_calc
      // равен радиусу пули даже при идеальном попадании в центр.
      expect(scoreForRadius(0, outwardPistol), closeTo(10.4, 1e-9));
      expect(scoreForRadius(0, TargetFace.pistol10m), closeTo(10.9, 1e-9));
    });
  });

  group('radiusForScore — обратная функция для слайдера десятых', () {
    test('round-trip на всех 400 сочетаниях мишень × габарит × десятая', () {
      for (final face in TargetFace.all) {
        for (var ring = 1; ring <= 10; ring++) {
          for (var decimal = 0; decimal <= 9; decimal++) {
            final radius = radiusForScore(ring, decimal, face);
            expect(
              scoreForRadius(radius, face),
              closeTo(ring + decimal / 10, 1e-9),
              reason: '${face.name}: габарит $ring, десятая $decimal, радиус $radius',
            );
          }
        }
      }
    });

    test('внутри габарита радиус растёт по мере падения десятой', () {
      const face = TargetFace.rifle50m;
      var prev = -1.0;
      for (var decimal = 9; decimal >= 0; decimal--) {
        final r = radiusForScore(10, decimal, face);
        expect(r, greaterThan(prev), reason: 'десятая $decimal');
        prev = r;
      }
    });

    test('несуществующий габарит не роняет расчёт', () {
      expect(radiusForScore(11, 0, TargetFace.rifle50m), 0.0);
      expect(radiusForScore(0, 0, TargetFace.rifle50m), 0.0);
    });
  });

  group('clockDirection — мнемоника "часы" (B.4/A.6)', () {
    test('вверх (0,+y) -> 12 часов', () {
      expect(clockDirection(_shotAt(0, 5)), 12);
    });

    test('вправо (+x,0) -> 3 часа', () {
      expect(clockDirection(_shotAt(5, 0)), 3);
    });

    test('вниз (0,-y) -> 6 часов', () {
      expect(clockDirection(_shotAt(0, -5)), 6);
    });

    test('влево (-x,0) -> 9 часов', () {
      expect(clockDirection(_shotAt(-5, 0)), 9);
    });
  });
}

// Хелпер — конструирует Shot с нужными координатами для тестов
// направления/часов, остальные поля не важны для clockDirection().
Shot _shotAt(double x, double y) {
  return Shot(
    id: 'test',
    shotNumber: 1,
    seriesNo: 1,
    xMm: x,
    yMm: y,
    score: 0,
    time: DateTime(2026, 1, 1),
  );
}
