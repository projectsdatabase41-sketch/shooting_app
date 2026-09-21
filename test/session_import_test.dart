import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/services/session_import.dart';

Map<String, dynamic> shot(int n, {int series = 1, double score = 10.5}) => {
      'n': n,
      'series': series,
      'x_mm': 0.4,
      'y_mm': -1.2,
      'score': score,
      'time': '2023-06-26T12:37:18',
      'extra': {'время_прицеливания_с': 18.4},
    };

Map<String, dynamic> bundle({
  Object? format = SessionImport.formatId,
  Object? version = 1,
  List<Map<String, dynamic>>? shots,
  String faceCode = 'rifle_10m',
  Object? startedAt = '2023-06-26T12:37:00',
}) =>
    {
      'format': format,
      'version': version,
      'source': 'SCATT Expert',
      'sessions': [
        {
          'exercise': {
            'code': 'ВП-20',
            'name': 'Пневматическая винтовка 10 м',
            'target_face_code': faceCode,
            'total_shots': 20,
            'series_size': 10,
          },
          'started_at': startedAt,
          'finished_at': '2023-06-26T12:49:23',
          'extra': {'прибор': 'SCATT'},
          'shots': shots ?? [shot(1), shot(2, score: 9.8)],
        }
      ],
    };

void main() {
  group('Разбор файла импорта', () {
    test('нормальный файл разбирается целиком', () {
      final b = SessionImport.parse(jsonEncode(bundle()));

      expect(b.sessions.length, 1);
      expect(b.shotCount, 2);
      expect(b.source, 'SCATT Expert');

      final s = b.sessions.first;
      expect(s.label, 'Пневматическая винтовка 10 м');
      expect(s.session.shots.first.xMm, 0.4);
      expect(s.session.totalScore, closeTo(20.3, 1e-9));
      // Тренировка из отчёта — уже состоявшаяся, не «не начата».
      expect(s.session.status.name, 'finished');
    });

    test('результат из отчёта не пересчитывается по координатам', () {
      final b = SessionImport.parse(jsonEncode(bundle()));
      // Флаг ручной правки — единственное, что защищает импортированный
      // результат от пересчёта: координаты восстановлены с точностью
      // около сотой миллиметра, и на границе десятой доли пересчёт дал
      // бы другое число.
      expect(b.sessions.first.session.shots.every((s) => s.isManuallyEdited), isTrue);
    });

    test('показатели прибора сохраняются рядом с выстрелом', () {
      final b = SessionImport.parse(jsonEncode(bundle()));
      expect(b.sessions.first.session.shots.first.extra?['время_прицеливания_с'], 18.4);
      expect(b.sessions.first.session.extra?['прибор'], 'SCATT');
      // Пометка источника добавляется всегда — чтобы потом было видно,
      // что тренировка импортирована, а не набита руками.
      expect(b.sessions.first.session.extra?['импортировано_из'], 'SCATT Expert');
    });

    test('номера серий и выстрелов переносятся как есть', () {
      final b = SessionImport.parse(jsonEncode(bundle(shots: [
        shot(1, series: 1),
        shot(2, series: 1),
        shot(3, series: 2),
      ])));
      final shots = b.sessions.first.session.shots;
      expect(shots.map((s) => s.shotNumber), [1, 2, 3]);
      expect(shots.map((s) => s.seriesNo), [1, 1, 2]);
    });
  });

  group('Файл отклоняется целиком, а не наполовину', () {
    // Параметр НЕ называть `contains`: он перекроет матчер `contains`
    // из flutter_test, и вызов `contains(...)` перестанет быть вызовом
    // функции. Анализатор ловит это как ошибку, компилятор — тоже.
    void rejects(Object? json, String fragment) {
      expect(
        () => SessionImport.parse(json is String ? json : jsonEncode(json)),
        throwsA(isA<ImportException>()
            .having((e) => e.message, 'сообщение', contains(fragment))),
      );
    }

    test('не JSON', () => rejects('это не json', 'не JSON'));

    test('чужой формат', () => rejects(bundle(format: 'scatt.raw'), 'Чужой формат'));

    test('версия новее приложения', () => rejects(bundle(version: 99), 'новее'));

    test('нет тренировок', () {
      rejects({'format': SessionImport.formatId, 'version': 1, 'sessions': []},
          'нет ни одной тренировки');
    });

    test('неизвестная мишень', () => rejects(bundle(faceCode: 'lasertag'), 'неизвестная мишень'));

    test('нет даты начала', () => rejects(bundle(startedAt: null), 'дата начала'));

    test('результат вне шкалы', () {
      // 11.0 не существует ни на одной мишени — такой файл битый, и
      // принять его частично нельзя: сумма тренировки станет ложью.
      rejects(bundle(shots: [shot(1, score: 11.0)]), 'вне шкалы');
    });

    test('номер тренировки попадает в текст ошибки', () {
      rejects(bundle(shots: [shot(1, score: 12.0)]), 'Тренировка 1');
    });
  });

  group('Координаты из результата и направления (когда их нет в файле)', () {
    ImportedSession parseShots(List<Map<String, dynamic>> shots, {String face = 'rifle_10m'}) =>
        SessionImport.parse(jsonEncode(bundle(shots: shots, faceCode: face))).sessions.first;

    test('результат + направление: приложение само считает координаты, и они дают тот же результат', () {
      // Все 4 мишени × кольца 1..10 × десятые 0..9 — обратная задача
      // должна возвращать ровно тот результат, что был во входе.
      for (final face in TargetFace.all) {
        for (var ring = 1; ring <= 10; ring++) {
          for (var dec = 0; dec <= 9; dec++) {
            final score = ring + dec / 10;
            final shot = parseShots([
              {'n': 1, 'score': score, 'angle_deg': 37}
            ], face: face.code).session.shots.first;
            expect(scoreFor(shot, face), closeTo(score, 1e-9), reason: '${face.code} $score');
          }
        }
      }
    });

    test('направление: часы, стрелки и градусы дают один и тот же угол (0 — вверх, по часовой)', () {
      double angle(Map<String, dynamic> dir) {
        final s = parseShots([
          {'n': 1, 'score': 9.0, ...dir}
        ]).session.shots.first;
        return s.angleDeg;
      }

      expect(angle({'clock': '12'}), closeTo(0, 1e-6));
      expect(angle({'clock': 3}), closeTo(90, 1e-6));
      expect(angle({'clock': '6:00'}), closeTo(180, 1e-6));
      expect(angle({'clock': '9:30'}), closeTo(285, 1e-6));
      expect(angle({'direction': '→'}), closeTo(90, 1e-6));
      expect(angle({'direction': 'SW'}), closeTo(225, 1e-6));
      expect(angle({'direction': 'ЮЗ'}), closeTo(225, 1e-6));
      expect(angle({'angle_deg': 350}), closeTo(350, 1e-6));
    });

    test('ось Y вверх: направление «вверх» — положительный y_mm', () {
      final s = parseShots([
        {'n': 1, 'score': 9.0, 'direction': '↑'}
      ]).session.shots.first;
      expect(s.yMm, greaterThan(0));
      expect(s.xMm.abs(), lessThan(1e-9));
    });

    test('направления нет: радиус верный, углы разные, положение помечено условным', () {
      final shots = parseShots([
        for (var i = 1; i <= 5; i++) {'n': i, 'score': 9.0}
      ]).session.shots;
      const face = TargetFace.rifle10m;
      for (final s in shots) {
        expect(scoreFor(s, face), closeTo(9.0, 1e-9));
        expect(s.extra?['координаты'], contains('условное'));
      }
      expect(shots.map((s) => s.angleDeg.round()).toSet().length, 5);
    });

    test('заданные x_mm и y_mm не трогаются и не помечаются', () {
      final s = parseShots([shot(1)]).session.shots.first;
      expect(s.xMm, 0.4);
      expect(s.yMm, -1.2);
      expect(s.extra?.containsKey('координаты'), isFalse);
    });

    test('только одна из координат — файл отклоняется', () {
      expect(
        () => SessionImport.parse(jsonEncode(bundle(shots: [
          {'n': 1, 'score': 9.0, 'x_mm': 1.0}
        ]))),
        throwsA(isA<ImportException>().having((e) => e.message, 'сообщение', contains('оба'))),
      );
    });
  });

  test('формула из публичной инструкции (R10, W, К по мишени) совпадает с radiusForScore', () {
    // Тот же текст лежит в qwen_public_instructions («Как определить
    // координаты выстрела») — если геометрия мишени изменится, тест
    // подскажет, что инструкцию пора обновить.
    const table = {
      'rifle_10m': (0.25, 2.5, 2.25),
      'pistol_10m': (5.75, 8.0, 2.25),
      'rifle_50m': (5.2, 8.0, 2.8),
      'pistol_25m': (25.0, 25.0, 2.8),
    };
    for (final face in TargetFace.all) {
      final (r10, w, k) = table[face.code]!;
      for (var ring = 1; ring <= 10; ring++) {
        for (var dec = 0; dec <= 9; dec++) {
          final d = r10 + w * (10 - ring) - (dec + 0.5) * w / 10 + k;
          expect(d < 0 ? 0.0 : d, closeTo(radiusForScore(ring, dec, face), 1e-9), reason: '${face.code} $ring.$dec');
        }
      }
    }
    expect(radiusForScore(10, 6, TargetFace.rifle50m), closeTo(2.8, 1e-9));
    expect(radiusForScore(10, 6, TargetFace.rifle10m), closeTo(0.875, 1e-9));
    expect(radiusForScore(9, 0, TargetFace.pistol25m), closeTo(51.55, 1e-9));
  });
}
