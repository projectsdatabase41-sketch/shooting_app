import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
    void rejects(Object? json, String contains) {
      expect(
        () => SessionImport.parse(json is String ? json : jsonEncode(json)),
        throwsA(isA<ImportException>()
            .having((e) => e.message, 'сообщение', contains(contains))),
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
}
