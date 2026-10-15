import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/models/target_face.dart';

FinalRunController _make(int seed, {BotDifficulty d = BotDifficulty.medium, FinalFormat format = FinalFormat.airRifle10m}) {
  final face = TargetFace.byCode(format.faceCode);
  final rng = math.Random(seed);
  const stats = ShotStats(0.5, -0.5, 3.0, 3.0, 100);
  final competitors = [
    FinalCompetitor('me', 'Я', isUser: true),
    for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i'),
  ];
  return FinalRunController(
    format: format,
    face: face,
    engine: FinalEngine(format, competitors),
    userId: 'me',
    bots: {for (var i = 1; i <= 7; i++) 'b$i': BotShooter(stats, d, face, math.Random(seed * 31 + i))},
    rng: rng,
  );
}

/// Прогоняет финал; человек стреляет в [aim] каждый раз, когда может.
int _run(FinalRunController c, {(double, double)? aim, int maxTicks = 20000}) {
  var ticks = 0;
  while (c.phase != RunPhase.finished && ticks < maxTicks) {
    if (aim != null) {
      while (c.userCanShoot) {
        c.submitUserShot(aim.$1, aim.$2);
      }
    }
    c.tick();
    ticks++;
  }
  return ticks;
}

void main() {
  test('подготовка 5 минут → «заряжай» 5 с → серия; пристрелку можно пропустить', () {
    final c = _make(1);
    expect(c.phase, RunPhase.sighting);
    expect(c.secondsLeft, 300);
    c.skipSighting();
    expect(c.phase, RunPhase.loading);
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.shooting);
    expect(c.roundLimit, 250);
    expect(c.shotsPerShooter, 5);
    expect(c.userCanShoot, isTrue);
    expect(c.userShotsLeft, 5);
  });

  test('полный финал с человеком: у всех места 1…8, 24 зачётных выстрела у тех, кто дошёл', () {
    final c = _make(3);
    c.skipSighting();
    _run(c, aim: (0.0, 0.0));
    expect(c.phase, RunPhase.finished);
    final places = [for (final x in c.engine.competitors) x.place];
    expect(places.toSet(), {1, 2, 3, 4, 5, 6, 7, 8});
    final winner = c.engine.competitors.firstWhere((x) => x.place == 1);
    final second = c.engine.competitors.firstWhere((x) => x.place == 2);
    expect(winner.shots.length, 24);
    expect(second.shots.length, 24);
    // Выбывший 8-м остановился на 12 выстрелах.
    expect(c.engine.competitors.firstWhere((x) => x.place == 8).shots.length, 12);
    // 12+14+16+18+20+22+24+24 зачётных выстрелов (плюс перестрелочные, если были).
    expect(c.shots.length, greaterThanOrEqualTo(150));
    expect(c.engine.competitors.fold<int>(0, (a, x) => a + x.shots.length), 150);
    // Человек стрелял в центр: десятки.
    expect(c.user.shots.every((s) => s >= 10.0 || s == 0.0), isTrue);
    final rec = c.toRecord();
    expect(rec['format'], 'air_rifle_10m');
    expect((rec['standings'] as List).length, 8);
  });

  test('человек не стреляет: нули за невыстрелянные, финал всё равно доходит до конца', () {
    final c = _make(5);
    c.skipSighting();
    final ticks = _run(c);
    expect(c.phase, RunPhase.finished);
    expect(c.user.place, 8); // с нулями он последний и выбывает после 12-го
    expect(c.user.shots.length, 12);
    expect(c.user.shots.every((s) => s == 0.0), isTrue);
    expect(c.log.where((e) => e['e'] == 'timeout' && e['who'] == 'me').isNotEmpty, isTrue);
    // 2 серии по 250 с + 2 одиночных до 12-го выстрела уже дали выбывание; всё — не дольше нескольких тысяч секунд.
    expect(ticks, lessThan(2000));
  });

  test('пауза замораживает время и пишется в журнал', () {
    final c = _make(7);
    c.skipSighting();
    c.pause();
    final before = (c.secondsLeft, c.clock, c.roundSeconds);
    for (var i = 0; i < 50; i++) {
      c.tick();
    }
    expect((c.secondsLeft, c.clock, c.roundSeconds), before);
    expect(c.userCanShoot, isFalse);
    c.resume();
    c.tick();
    expect(c.secondsLeft, 4);
    expect(c.log.map((e) => e['e']), ['pause', 'resume']);
  });

  test('боты разной сложности: средний результат сильного соперника выше', () {
    double avgOfBots(BotDifficulty d) {
      var sum = 0.0, n = 0;
      for (var seed = 1; seed <= 6; seed++) {
        final c = _make(seed, d: d);
        c.skipSighting();
        _run(c, aim: (0.0, 0.0));
        for (final b in c.engine.competitors.where((x) => !x.isUser)) {
          sum += b.totalAt(12);
          n++;
        }
      }
      return sum / n;
    }

    expect(avgOfBots(BotDifficulty.easy), lessThan(avgOfBots(BotDifficulty.hard)));
  });

  test('«назад» убирает выстрел; после «Стоп» ещё 10 с на отметку', () {
    final c = _make(11);
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    c.submitUserShot(0, 0);
    c.submitUserShot(1, 1);
    expect(c.staged.length, 2);
    expect(c.undoUserShot(), isTrue);
    expect(c.staged.length, 1);
    for (var i = 0; i < 250; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.grace); // 4 выстрела не отмечены — окно открыто
    expect(c.userCanShoot, isTrue);
    c.submitUserShot(0, 0);
    for (var i = 0; i < 10; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.loading);
    expect(c.user.shots.length, 5); // 2 отмеченных + 3 нуля
    expect(c.user.shots.where((v) => v == 0.0).length, 3);
    expect(c.staged, isEmpty);
  });

  test('все отстреляли — «Стоп» раньше срока; диктор перед следующей командой', () {
    final c = _make(13);
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    for (var i = 0; i < 5; i++) {
      c.submitUserShot(0, 0);
    }
    var t = 0;
    while (c.phase == RunPhase.shooting && t < 300) {
      c.tick();
      t++;
    }
    expect(t, lessThan(250));
    expect(c.phase, RunPhase.loading);
    expect(c.announcing, isTrue);
    expect(c.secondsLeft, FinalRunController.announcerSeconds + 5);
  });

  test('50 м, три положения: полный финал с открытым этапом на 20 выстрелов', () {
    final c = _make(21, format: FinalFormat.rifle3p50m);
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    expect(c.roundLabel, 'open');
    expect(c.shotsPerShooter, 20);
    expect(c.roundLimit, 1320);
    _run(c, aim: (0.0, 0.0), maxTicks: 40000);
    expect(c.phase, RunPhase.finished);
    final places = [for (final x in c.engine.competitors) x.place];
    expect(places.toSet(), {1, 2, 3, 4, 5, 6, 7, 8});
    expect(c.engine.competitors.firstWhere((x) => x.place == 1).shots.length, 35);
  });

  test('выбыл — боты стреляют дальше; «Завершить результат» доигрывает остаток', () {
    final c = _make(5);
    c.skipSighting();
    // Человек не стреляет, выбывает 8-м после 12 выстрелов; ждём выбывания.
    var guard = 0;
    while (c.user.active && guard++ < 5000) {
      c.tick();
    }
    expect(c.user.active, isFalse);
    expect(c.phase, isNot(RunPhase.finished));
    final before = c.shots.length;
    for (var i = 0; i < 120; i++) {
      c.tick();
    }
    expect(c.shots.length, greaterThan(before)); // боты продолжают
    expect(c.fastForward(), isTrue);
    expect(c.phase, RunPhase.finished);
    expect({for (final x in c.engine.competitors) x.place}, {1, 2, 3, 4, 5, 6, 7, 8});
  });

  test('живая таблица: отмеченный выстрел спортсмена сразу меняет его место', () {
    final c = _make(31);
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    // Пока никто не стрелял, у всех 0; десятка в центр — спортсмен на первом месте.
    c.submitUserShot(0, 0);
    expect(c.live.first.c.isUser, isTrue);
    expect(c.live.first.avg, greaterThan(10));
    c.undoUserShot();
    expect(c.live.first.avg, 0);
  });

  test('несколько людей: каждый ставит свои выстрелы, раунд ждёт всех, нули за неотмеченное', () {
    final face = TargetFace.rifle10m;
    const stats = ShotStats(0, 0, 3.0, 3.0, 100);
    final competitors = [
      FinalCompetitor('a', 'A', isUser: true),
      FinalCompetitor('h', 'H'),
      for (var i = 1; i <= 6; i++) FinalCompetitor('b$i', 'Бот $i'),
    ];
    final c = FinalRunController(
      format: FinalFormat.airRifle10m,
      face: face,
      engine: FinalEngine(FinalFormat.airRifle10m, competitors),
      userId: 'a',
      otherHumans: {'h'},
      bots: {for (var i = 1; i <= 6; i++) 'b$i': BotShooter(stats, BotDifficulty.medium, face, math.Random(i))},
      rng: math.Random(1),
    );
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    expect(c.canShootFor('h'), isTrue);
    for (var i = 0; i < 5; i++) {
      c.submitUserShot(0, 0);
    }
    c.submitShotFor('h', 0, 0);
    c.submitShotFor('h', 0, 0);
    c.undoShotFor('h');
    for (var i = 0; i < 250; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.grace); // у H не все выстрелы
    for (var i = 0; i < 10; i++) {
      c.tick();
    }
    final h = c.engine.byId('h');
    expect(h.shots.length, 5);
    expect(h.shots.where((v) => v == 0.0).length, 4); // 1 отмечен + 4 нуля
    expect(c.engine.byId('a').shots.length, 5);
  });

  test('свой финал без серий и с другим временем доходит до конца', () {
    final f = FinalFormat.custom(faceCode: 'rifle_10m', series: 0, perSeries: 5, singles: 14, seriesSeconds: 100, singleSeconds: 20, step: 2)!;
    final c = _make(41, format: f);
    c.skipSighting();
    _run(c, aim: (0.0, 0.0), maxTicks: 40000);
    expect(c.phase, RunPhase.finished);
    expect({for (final x in c.engine.competitors) x.place}, {1, 2, 3, 4, 5, 6, 7, 8});
  });
}
