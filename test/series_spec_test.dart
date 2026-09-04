import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/session_logic.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/series_spec.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';

/// Упражнение со свободной структурой: пристрелка 15 минут без зачёта,
/// потом 3 зачётных выстрела, потом остаток. Специально короткие серии —
/// длинные ничего не проверяют, только раздувают тест.
const flexible = Exercise(
  id: 'ex_flex',
  name: 'Смешанное',
  targetFaceCode: 'rifle_10m',
  totalShots: 8,
  seriesSize: 3,
  series: [
    SeriesSpec(name: 'Пристрелка', timeLimit: Duration(minutes: 15), counts: false),
    SeriesSpec(name: 'Лёжа', shotCount: 3),
    SeriesSpec(name: 'Стоя', shotCount: 3),
  ],
);

const plain = Exercise(
  id: 'ex_plain',
  name: 'ВП-60',
  targetFaceCode: 'rifle_10m',
  totalShots: 60,
  seriesSize: 10,
);

void main() {
  group('SeriesSpec', () {
    test('round-trip через JSON', () {
      const spec = SeriesSpec(
        name: 'Пристрелка',
        timeLimit: Duration(minutes: 15),
        counts: false,
      );
      final restored = SeriesSpec.fromJson(spec.toJson());
      expect(restored, spec);
      expect(restored.isTimed, isTrue);
    });

    test('список серий переживает строку базы', () {
      const list = [
        SeriesSpec(name: 'Пристрелка', timeLimit: Duration(minutes: 15), counts: false),
        SeriesSpec(name: 'Лёжа', shotCount: 10),
      ];
      expect(seriesFromJson(seriesToJson(list)), list);
    });

    test('битая строка — это отсутствие серий, а не падение', () {
      expect(seriesFromJson('не json'), isEmpty);
      expect(seriesFromJson(''), isEmpty);
      expect(seriesFromJson(null), isEmpty);
      expect(seriesFromJson('{"а":1}'), isEmpty);
    });

    test('подпись склоняет «выстрел» и помечает отсутствие зачёта', () {
      expect(const SeriesSpec(name: 'Лёжа', shotCount: 1).label, 'Лёжа · 1 выстрел');
      expect(const SeriesSpec(name: 'Лёжа', shotCount: 3).label, 'Лёжа · 3 выстрела');
      expect(const SeriesSpec(name: 'Лёжа', shotCount: 10).label, 'Лёжа · 10 выстрелов');
      expect(const SeriesSpec(name: 'Лёжа', shotCount: 11).label, 'Лёжа · 11 выстрелов');
      expect(
        const SeriesSpec(name: 'Пристрелка', timeLimit: Duration(minutes: 15), counts: false)
            .label,
        'Пристрелка · 15 мин · без зачёта',
      );
    });

    test('copyWith умеет очищать границу — иначе не переключить тип', () {
      const byCount = SeriesSpec(name: 'Лёжа', shotCount: 10);
      final byTime = byCount.copyWith(
        clearShotCount: true,
        timeLimit: const Duration(minutes: 5),
      );
      expect(byTime.shotCount, isNull);
      expect(byTime.isTimed, isTrue);
      expect(byTime.copyWith(clearTimeLimit: true, shotCount: 10), byCount);
    });
  });

  group('Нумерация серий', () {
    final t0 = DateTime(2026, 9, 4, 10, 0);

    TrainingSession sessionWith(List<DateTime> times) {
      var s = const TrainingSession(
        id: 's1',
        exerciseId: 'ex_flex',
        targetFaceCode: 'rifle_10m',
      );
      s = SessionLogic.start(s, t0);
      for (final t in times) {
        s = SessionLogic.addShot(s, flexible, TargetFace.rifle10m, 0.4, 0.2, t);
      }
      return s;
    }

    test('без описания серий работает старое деление', () {
      const empty = TrainingSession(
        id: 's0',
        exerciseId: 'ex_plain',
        targetFaceCode: 'rifle_10m',
      );
      expect(SessionLogic.seriesNoFor(empty, plain, 1, t0), 1);
      expect(SessionLogic.seriesNoFor(empty, plain, 10, t0), 1);
      expect(SessionLogic.seriesNoFor(empty, plain, 11, t0), 2);
      expect(SessionLogic.seriesNoFor(empty, plain, 60, t0), 6);
    });

    test('серия по времени закрывается по часам, а не по выстрелам', () {
      // Три выстрела внутри пятнадцатиминутной пристрелки.
      final s = sessionWith([
        t0.add(const Duration(minutes: 1)),
        t0.add(const Duration(minutes: 2)),
        t0.add(const Duration(minutes: 3)),
      ]);
      expect(s.shots.map((e) => e.seriesNo), [1, 1, 1]);
      // Следующий выстрел — уже после истечения времени, хотя новых
      // выстрелов между ними не было.
      expect(
        SessionLogic.seriesNoFor(s, flexible, 4, t0.add(const Duration(minutes: 16))),
        2,
      );
    });

    test('серия по выстрелам закрывается по счётчику', () {
      // Первый выстрел закрывает пристрелку по времени, дальше — по три.
      var s = sessionWith([t0.add(const Duration(minutes: 1))]);
      for (var i = 0; i < 6; i++) {
        s = SessionLogic.addShot(
          s,
          flexible,
          TargetFace.rifle10m,
          0.4,
          0.2,
          t0.add(Duration(minutes: 16 + i)),
        );
      }
      expect(s.shots.map((e) => e.seriesNo), [1, 2, 2, 2, 3, 3, 3]);
    });

    test('лишние выстрелы остаются в последней серии, а не улетают в 4-ю', () {
      var s = sessionWith([t0.add(const Duration(minutes: 1))]);
      for (var i = 0; i < 8; i++) {
        s = SessionLogic.addShot(
          s,
          flexible,
          TargetFace.rifle10m,
          0.4,
          0.2,
          t0.add(Duration(minutes: 16 + i)),
        );
      }
      expect(s.shots.last.seriesNo, 3);
    });
  });

  group('Зачёт', () {
    final t0 = DateTime(2026, 9, 4, 10, 0);

    test('выстрелы пристрелки помечаются незачётными и не идут в сумму', () {
      var s = const TrainingSession(
        id: 's2',
        exerciseId: 'ex_flex',
        targetFaceCode: 'rifle_10m',
      );
      s = SessionLogic.start(s, t0);
      // Один в пристрелке, один — после её конца.
      s = SessionLogic.addShot(
        s, flexible, TargetFace.rifle10m, 0, 0, t0.add(const Duration(minutes: 1)));
      s = SessionLogic.addShot(
        s, flexible, TargetFace.rifle10m, 0, 0, t0.add(const Duration(minutes: 16)));

      expect(s.shots.first.counts, isFalse);
      expect(s.shots.last.counts, isTrue);
      expect(s.countingShots.length, 1);
      // Оба — центр, по 10.9. В сумму идёт только зачётный.
      expect(s.shots.first.score, closeTo(10.9, 1e-9));
      expect(s.totalScore, closeTo(10.9, 1e-9));
    });

    test('у упражнения без описания серий зачёт у всех', () {
      expect(plain.countsSeries(1), isTrue);
      expect(plain.countsSeries(7), isTrue);
      expect(flexible.countsSeries(1), isFalse);
      expect(flexible.countsSeries(2), isTrue);
      // За пределами описания — обычная серия.
      expect(flexible.countsSeries(9), isTrue);
      expect(flexible.specFor(9), isNull);
    });
  });
}
