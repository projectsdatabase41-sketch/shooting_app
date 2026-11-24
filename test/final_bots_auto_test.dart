import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/finals/rank_norms.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/target_face.dart';

const _ranks = [
  '3 юношеский',
  '2 юношеский',
  '1 юношеский',
  '3 взрослый',
  '2 взрослый',
  '1 взрослый',
  'КМС',
  'МС',
  'МСМК',
];

void main() {
  group('нормативная таблица (rank_norms.dart)', () {
    test('монотонность по разрядам: средний растёт, разброс падает', () {
      // Отзыв владельца 24.11: бот без истории тренировок берётся из разряда —
      // поэтому уровни обязаны быть упорядочены по разрядам.
      for (final faceKey in kBotRankNorms.keys) {
        for (var i = 1; i < _ranks.length; i++) {
          final prev = _ranks[i - 1], cur = _ranks[i];
          expect(RankNorms.averageFor(faceKey, cur),
              greaterThan(RankNorms.averageFor(faceKey, prev)),
              reason: '$faceKey: средний разряда «$cur» выше «$prev»');
          expect(RankNorms.spreadFor(faceKey, cur),
              lessThan(RankNorms.spreadFor(faceKey, prev)),
              reason: '$faceKey: разброс разряда «$cur» меньше «$prev»');
        }
      }
    });

    test('символические расшифровки: rifle_50m = 3P, ЗМС = МСМК, пусто = 3 взрослый', () {
      expect(RankNorms.averageFor('rifle_50m', 'МС'), RankNorms.averageFor('rifle_50m_3p', 'МС'));
      expect(RankNorms.averageFor('rifle_10m', 'ЗМС'), RankNorms.averageFor('rifle_10m', 'МСМК'));
      expect(RankNorms.averageFor('rifle_10m', ''), RankNorms.averageFor('rifle_10m', '3 взрослый'));
      expect(RankNorms.averageFor('rifle_10m', 'Нет разряда'),
          RankNorms.averageFor('rifle_10m', '3 взрослый'));
      // Неизвестные коды не падают и остаются в разумных пределах.
      expect(RankNorms.averageFor('неизвестная_мишень', 'кто-то'), inInclusiveRange(0, 10.9));
    });
  });

  group('ЕВСК 2026–2029 (приказ Минспорта от 10.03.2026 № 201, прил. 22; владелец 24.11)', () {
    test('avg = нормативная сумма / число выстрелов; целые → десятичный эквивалент', () {
      // В таблицу ботов средний выстрел записан с точностью до тысячных —
      // для калибровки бота этого достаточно, поэтому допуск 1e-3.
      // ВП-60 (десятые): 629.5/60, 606.0/60; III только в целых: 560/60.
      expect(RankNorms.averageFor('rifle_10m', 'МСМК'), closeTo(629.5 / 60, 1e-3));
      expect(RankNorms.averageFor('rifle_10m', '1 взрослый'), closeTo(606.0 / 60, 1e-3));
      expect(RankNorms.averageFor('rifle_10m', '3 взрослый'), closeTo(560 / 60, 1e-3));
      // Юношеские маппируются на возрастное упражнение: ВП-40, I юн. 360/40.
      expect(RankNorms.averageFor('rifle_10m', '1 юношеский'), closeTo(360 / 40, 1e-3));
      // ПП-60: 578/60; III нет → из ПП-40: 336/40.
      expect(RankNorms.averageFor('pistol_10m', 'МС'), closeTo(578 / 60, 1e-3));
      expect(RankNorms.averageFor('pistol_10m', '3 взрослый'), closeTo(336 / 40, 1e-3));
      // МВ-3×40 (120 выстрелов): 1160/120; II нет → МВ-3×20, II: 540/60.
      expect(RankNorms.averageFor('rifle_50m', 'МС'), closeTo(1160 / 120, 1e-3));
      expect(RankNorms.averageFor('rifle_50m', '2 взрослый'), closeTo(540 / 60, 1e-3));
    });

    test('предметы ЕВСК и коды мишеней ведут в одну таблицу ботов', () {
      expect(RankNorms.averageFor('ВП-60', 'МС'), RankNorms.averageFor('rifle_10m', 'МС'));
      expect(RankNorms.averageFor('ПП-40', 'КМС'), RankNorms.averageFor('pistol_10m', 'КМС'));
      expect(RankNorms.averageFor('МВ-3×40', 'МСМК'), RankNorms.averageFor('rifle_50m', 'МСМК'));
      // Сырые суммы справочника ЕВСК доступны для выверки.
      expect(RankNorms.ewskSumFor('ПП-40', 'I'), closeTo(363, 1e-9));
      expect(RankNorms.ewskSumFor('МВ-60 (десятые)', 'КМС'), closeTo(617.0, 1e-9));
    });
  });

  group('авто-уровень бота (отзыв владельца 24.11)', () {
    const face = TargetFace.rifle50m;
    final rng = math.Random(11);
    // Случайная «манера» спортсмена: СТП с уводом и разброс.
    final pts = [for (var i = 0; i < 60; i++) (1.0 + 6 * _g(rng), -0.5 + 6 * _g(rng))];
    final stats = ShotStats.fromPoints(pts);
    final athleteAvg =
        pts.map((p) => scoreForPoint(p.$1, p.$2, face)).reduce((a, b) => a + b) / pts.length;

    test('калибровка: средний результат бота равен среднему спортсмена', () {
      final bot = BotShooter(BotShooter.calibrated(stats, athleteAvg, face),
          BotDifficulty.auto, face, math.Random(5));
      final scores = [for (var i = 0; i < 4000; i++) bot.nextScore()];
      final avg = scores.reduce((a, b) => a + b) / scores.length;
      // Не «случайные 3–5 очков», а ровно уровень спортсмена (допуск на
      // конечность выборки).
      expect(avg, closeTo(athleteAvg, 0.15));
      // Оценка по детерминированной решётке — точнее.
      expect(BotShooter.meanScoreFor(bot.stats, face), closeTo(athleteAvg, 0.02));
    });

    test('норматив: forAverage даёт средний выстрел по таблице разрядов', () {
      for (final rank in _ranks) {
        final avg = RankNorms.averageFor(face.code, rank);
        final st = BotShooter.forAverage(avg, RankNorms.spreadFor(face.code, rank), face);
        expect(BotShooter.meanScoreFor(st, face), closeTo(avg, 0.05), reason: rank);
      }
    });

    test('диапазон по сложностям сохраняется и на калиброванной статистике', () {
      double mean(BotDifficulty d) {
        final bot = BotShooter(BotShooter.calibrated(stats, athleteAvg, face), d, face, math.Random(17));
        var sum = 0.0;
        for (var i = 0; i < 4000; i++) {
          sum += bot.nextScore();
        }
        return sum / 4000;
      }

      final easy = mean(BotDifficulty.easy), med = mean(BotDifficulty.auto), hard = mean(BotDifficulty.hard);
      expect(easy, lessThan(med));
      expect(med, lessThan(hard));
    });
  });

  group('изготовка в названии упражнения (отзыв владельца 24.11)', () {
    test('parse: лёжа / с колена / стоя / колено; без упоминания — null', () {
      expect(stanceFromName('МВ-9, лёжа'), stanceProne);
      expect(stanceFromName('Упражнение с колена'), stanceKneeling);
      expect(stanceFromName('МВ-9, колено'), stanceKneeling);
      expect(stanceFromName('ВП-4, стоя'), stanceStanding);
      expect(stanceFromName('МВ-9, мужчины'), isNull);
      expect(stanceFromName(''), isNull);
    });

    test('3P: бот в каждой изготовке стреляет своим уровнем, stance меняется по раундам', () {
      const face = TargetFace.rifle50m;
      const fmt = FinalFormat.rifle3p50m;
      final controller = FinalRunController(
        format: fmt,
        face: face,
        engine: FinalEngine(fmt, [
          FinalCompetitor('me', 'Я', isUser: true),
          for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i'),
        ]),
        userId: 'me',
        bots: {
          for (var i = 1; i <= 7; i++)
            'b$i': BotShooter(const ShotStats(0, 0, 3.0, 3.0, 100), BotDifficulty.auto, face,
                math.Random(i), byStance: {
              stanceProne: const ShotStats(0, 0, 1.0, 1.0, 100),
              stanceKneeling: const ShotStats(0, 0, 3.0, 3.0, 100),
              stanceStanding: const ShotStats(0, 0, 6.0, 6.0, 100),
            }),
        },
        rng: math.Random(1),
      );
      final stances = <String>{};
      var ticks = 0;
      while (controller.phase != RunPhase.finished && ticks < 20000) {
        if (controller.phase == RunPhase.shooting) {
          for (final id in controller.bots.keys) {
            stances.add(controller.bots[id]!.stance ?? '');
          }
        }
        for (final id in controller.missingIds) {
          while (controller.canShootFor(id)) {
            controller.markMiss(id);
          }
        }
        controller.tick();
        ticks++;
      }
      expect(controller.phase, RunPhase.finished);
      // Все три положения прошли: колено → лёжа → стоя, перестрелка — стоя.
      expect(stances, containsAll([stanceKneeling, stanceProne, stanceStanding]));
      expect(stances, isNot(contains('')));
    });
  });

  group('паузы ботов: отдых → прицеливание → перезарядка (отзыв владельца 24.11)', () {
    test('сумма стадий в пределах слота на выстрел; при плотном слоте сжимается', () {
      final rifle = BotShooter(const ShotStats(0, 0, 3, 3, 100), BotDifficulty.auto,
          TargetFace.rifle10m, math.Random(3));
      final pistol = BotShooter(const ShotStats(0, 0, 3, 3, 100), BotDifficulty.auto,
          TargetFace.pistol10m, math.Random(3));
      for (var i = 0; i < 50; i++) {
        // Обычный слот одиночных выстрелов: финал, 50 с на выстрел, лимит 50.
        final r1 = rifle.stagePause(50), p1 = pistol.stagePause(50);
        expect(r1.total, inInclusiveRange(9, 20)); // 4–9 + 3–7 + 2–4
        expect(p1.total, inInclusiveRange(5, 11)); // 2–5 + 2–4 + 1–2
        // Свой формат с плотной сеткой: слот меньше суммы — сжатие до слота.
        final r2 = rifle.stagePause(6);
        expect(r2.total, lessThanOrEqualTo(6));
        final r3 = rifle.stagePause(3);
        expect(r3.total, lessThanOrEqualTo(3));
      }
    });

    test('в финале: выстрелы ботов с зазором ≥5 с, внутри лимита, статус меняется rest/aim/reload', () {
      const face = TargetFace.rifle10m;
      const fmt = FinalFormat.airRifle10m;
      final controller = FinalRunController(
        format: fmt,
        face: face,
        engine: FinalEngine(fmt, [
          FinalCompetitor('me', 'Я', isUser: true),
          for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i'),
        ]),
        userId: 'me',
        bots: {
          for (var i = 1; i <= 7; i++)
            'b$i': BotShooter(const ShotStats(0, 0, 3.0, 3.0, 100), BotDifficulty.auto, face, math.Random(i)),
        },
        rng: math.Random(1),
      );
      controller.skipSighting();
      for (var i = 0; i < 5; i++) {
        controller.tick();
      }
      expect(controller.phase, RunPhase.shooting);
      expect(controller.roundLimit, 250);

      // Счётчики выстрелов каждого бота, чтобы поймать момент «только что выстрелил».
      final before = <String, int>{for (final id in controller.bots.keys) id: 0};
      final lastFireSecond = <String, int>{};
      final lastRoundId = <String, int>{};
      final seenStages = <String>{};
      var ticks = 0;
      while (controller.phase == RunPhase.shooting && ticks < 5000) {
        for (final id in controller.bots.keys) {
          final st = controller.botStageOf(id);
          if (st.isNotEmpty) seenStages.add(st);
        }
        for (final id in controller.missingIds) {
          while (controller.canShootFor(id)) {
            controller.markMiss(id);
          }
        }
        controller.tick();
        ticks++;
        for (final id in controller.bots.keys) {
          final n = controller.shots.where((s) => s.who == id && !s.shootOff).length;
          if (n > (before[id] ?? 0)) {
            before[id] = n;
            // Выстрел прозвучал на текущей секунде раунда: раньше конца раунда,
            // а от предыдущего — не быстрее чем через 5 с.
            expect(controller.roundSeconds, lessThanOrEqualTo(controller.roundLimit),
                reason: 'выстрел бота $id в пределах раунда');
            final prev = lastFireSecond[id], prevRound = lastRoundId[id];
            if (prev != null && prevRound == controller.roundId) {
              expect(controller.roundSeconds - prev, greaterThanOrEqualTo(5),
                  reason: 'зазор выстрелов бота $id');
            }
            lastFireSecond[id] = controller.roundSeconds;
            lastRoundId[id] = controller.roundId;
          }
        }
      }
      // Стадии реально сменяются: за серию бот успевает и отдохнуть, и
      // прицелиться, и перезарядить.
      expect(seenStages, containsAll(['rest', 'aim', 'reload']));
      expect(ticks, lessThan(5000));
    });
  });
}

/// Бокс — Мюллер, как в BotShooter: случайная «манера» спортсмена в тесте.
double _g(math.Random rng) {
  final u1 = 1 - rng.nextDouble(), u2 = rng.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}
