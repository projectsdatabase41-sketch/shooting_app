import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/target_face.dart';

FinalEngine _engine() => FinalEngine(FinalFormat.airRifle10m, [
      for (var i = 1; i <= 8; i++) FinalCompetitor('c$i', 'Участник $i', isUser: i == 1),
    ]);

/// Каждый участник [i] стреляет [k] выстрелов по 10.0 + i/10 (разные суммы).
void _fire(FinalEngine e, int shotsEach, {double Function(int i, int shot)? score}) {
  for (var s = 0; s < shotsEach; s++) {
    for (final c in e.active) {
      final i = int.parse(c.id.substring(1));
      if (c.shots.length > s) continue;
      e.submit(c.id, score != null ? score(i, s) : 9.0 + i / 10);
    }
  }
}

void main() {
  test('формат по ISSF 6.17.2: 8 финалистов, 2×5 + 14, 24 выстрела, время', () {
    const f = FinalFormat.airRifle10m;
    expect(f.finalists, 8);
    expect(f.seriesShots, [5, 5]);
    expect(f.singleShots, 14);
    expect(f.totalShots, 24);
    expect(f.seriesSeconds, 250);
    expect(f.singleSeconds, 50);
    expect(f.sightingSeconds, 300);
    expect(f.eliminationAfter, [12, 14, 16, 18, 20, 22]);
    expect(f.secondsForShot(0), 250);
    expect(f.secondsForShot(9), 250);
    expect(f.secondsForShot(10), 50);
    expect(f.secondsForShot(23), 50);
    expect(FinalFormat.airPistol10m.totalShots, 24);
  });

  test('выбывание: после 12-го выстрела уходит 8-й, дальше каждые два выстрела', () {
    final e = _engine();
    _fire(e, 11);
    expect(e.active.length, 8);
    _fire(e, 12);
    expect(e.active.length, 7);
    expect(e.byId('c1').place, 8); // самый слабый (9.1 за выстрел)
    _fire(e, 13);
    expect(e.active.length, 7);
    _fire(e, 14);
    expect(e.byId('c2').place, 7);
    _fire(e, 16);
    expect(e.byId('c3').place, 6);
    _fire(e, 18);
    expect(e.byId('c4').place, 5);
    _fire(e, 20);
    expect(e.byId('c5').place, 4);
    _fire(e, 22);
    expect(e.byId('c6').place, 3);
    expect(e.isFinished, isFalse);
    _fire(e, 24);
    expect(e.isFinished, isTrue);
    expect(e.byId('c8').place, 1);
    expect(e.byId('c7').place, 2);
    expect([for (final c in e.standings) c.id], ['c8', 'c7', 'c6', 'c5', 'c4', 'c3', 'c2', 'c1']);
    expect(() => e.submit('c8', 10), throwsStateError);
  });

  test('выбывший не стреляет дальше; сумма — десятые без хвостов', () {
    final e = _engine();
    _fire(e, 12);
    expect(() => e.submit('c1', 10), throwsStateError);
    expect(e.byId('c2').total, closeTo(12 * 9.2, 1e-9));
    expect(e.byId('c2').totalAt(3), 27.6);
  });

  test('ничья за выбывание: перестрелка, проигравший уходит, остальные продолжают', () {
    final e = _engine();
    // c1 и c2 набирают одинаково мало, остальные выше.
    _fire(e, 12, score: (i, s) => i <= 2 ? 9.0 : 10.0);
    expect(e.phase, FinalPhase.shootOff);
    expect([for (final c in e.shootOffShooters) c.id]..sort(), ['c1', 'c2']);
    expect(e.active.length, 8); // пока никто не выбыл
    e.submit('c1', 9.5);
    e.submit('c2', 9.5); // снова поровну — ещё круг
    expect(e.phase, FinalPhase.shootOff);
    e.submit('c1', 10.3);
    e.submit('c2', 9.8);
    expect(e.phase, FinalPhase.match);
    expect(e.byId('c2').place, 8);
    expect(e.byId('c1').active, isTrue);
    expect(e.byId('c1').shots.length, 12); // перестрелочные выстрелы в зачёт не идут
  });

  test('ничья за золото: перестрелка, лучший — первый', () {
    final e = _engine();
    _fire(e, 24, score: (i, s) => i >= 7 ? 10.0 : 9.0 + i / 100); // c7 и c8 равны
    expect(e.phase, FinalPhase.shootOff);
    e.submit('c7', 10.1);
    e.submit('c8', 10.6);
    expect(e.isFinished, isTrue);
    expect(e.byId('c8').place, 1);
    expect(e.byId('c7').place, 2);
  });

  test('нельзя стрелять сверх 24 выстрелов и без права на перестрелку', () {
    final e = _engine();
    _fire(e, 12, score: (i, s) => i <= 2 ? 9.0 : 10.0);
    expect(() => e.submit('c5', 10), throwsStateError); // не участвует в перестрелке
    expect(() => FinalEngine(FinalFormat.airRifle10m, [FinalCompetitor('a', 'a')]), throwsArgumentError);
  });

  group('боты', () {
    final face = TargetFace.rifle10m;
    final rng0 = math.Random(7);
    // Спортсмен: СТП (1.5, −1.0) мм, разброс 3 мм.
    double g() => (rng0.nextDouble() + rng0.nextDouble() + rng0.nextDouble() - 1.5) * 2; // ≈ N(0, 1)
    final pts = [for (var i = 0; i < 400; i++) (1.5 + 3 * g(), -1.0 + 3 * g())];
    final stats = ShotStats.fromPoints(pts);

    test('статистика: СТП и разброс найдены', () {
      expect(stats.mx, closeTo(1.5, 0.5));
      expect(stats.my, closeTo(-1.0, 0.5));
      expect(stats.sx, closeTo(3.0, 0.6));
      expect(stats.n, 400);
    });

    test('робастная статистика не раздувается от редкого промаха', () {
      final withMiss = [...pts, (40.0, 40.0)];
      expect(ShotStats.fromPoints(withMiss, robust: true).sx, lessThan(ShotStats.fromPoints(withMiss).sx));
    });

    double mean(BotDifficulty d) {
      final bot = BotShooter(stats, d, face, math.Random(11));
      var sum = 0.0;
      for (var i = 0; i < 4000; i++) {
        sum += bot.nextScore();
      }
      return sum / 4000;
    }

    test('сложность: лёгкий < средний < сложный на несколько десятых', () {
      final easy = mean(BotDifficulty.easy), med = mean(BotDifficulty.medium), hard = mean(BotDifficulty.hard);
      expect(easy, lessThan(med));
      expect(med, lessThan(hard));
      expect(med - easy, inInclusiveRange(0.05, 1.0));
      expect(hard - med, inInclusiveRange(0.05, 1.0));
    });

    test('средний бот стреляет как спортсмен (по среднему баллу)', () {
      final real = [for (final p in pts) scoreForPoint(p.$1, p.$2, face)];
      final avg = real.reduce((a, b) => a + b) / real.length;
      expect(mean(BotDifficulty.medium), closeTo(avg, 0.25));
    });

    test('непредсказуемый: по тренировкам, результаты в разумных пределах', () {
      final sessions = [
        ShotStats.fromPoints([for (var i = 0; i < 30; i++) (0.5 + 2 * g(), 0.2 + 2 * g())]),
        ShotStats.fromPoints([for (var i = 0; i < 30; i++) (3.0 + 5 * g(), -2.0 + 5 * g())]),
      ];
      final bot = BotShooter(stats, BotDifficulty.unpredictable, face, math.Random(5), sessions: sessions);
      final scores = [for (var i = 0; i < 500; i++) bot.nextScore()];
      expect(scores.every((s) => s >= 0 && s <= 10.9), isTrue);
      expect(bot.delaySeconds(50), inInclusiveRange(15, 42.6));
    });
  });
}
