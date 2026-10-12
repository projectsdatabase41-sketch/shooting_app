import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/finals/finals_net.dart';
import 'package:shooting_app/finals/finals_session_service.dart';
import 'package:shooting_app/models/target_face.dart';

FinalRunController _controller() {
  final face = TargetFace.rifle10m;
  const stats = ShotStats(0, 0, 3.0, 3.0, 100);
  final competitors = [
    FinalCompetitor('a', 'A'),
    FinalCompetitor('h', 'H'),
    for (var i = 1; i <= 6; i++) FinalCompetitor('b$i', 'Бот $i'),
  ];
  return FinalRunController(
    format: FinalFormat.airRifle10m,
    face: face,
    engine: FinalEngine(FinalFormat.airRifle10m, competitors),
    userId: 'a',
    otherHumans: {'h'},
    bots: {for (var i = 1; i <= 6; i++) 'b$i': BotShooter(stats, BotDifficulty.medium, face, math.Random(i))},
    rng: math.Random(1),
  );
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 400));

void main() {
  test('спортсмен стреляет только за себя, чужого — игнор; состояние доходит до участника', () async {
    final c = _controller();
    c.skipSighting();
    for (var i = 0; i < 5; i++) {
      c.tick();
    }
    final (hostCh, guestCh) = MemoryFinalsChannel.pair();
    final host = FinalsHost(
      controller: c,
      channel: hostCh,
      allowed: (author) => author == 'ath' ? {'h'} : null, // спортсмен H — только за себя; остальные — за всех
      canControl: (author) => author == 'coach',
    );
    final guest = FinalsGuest(channel: guestCh, userId: 'ath');
    guest.hello();
    await _settle();
    expect(guest.snapshot, isNotNull);
    expect(guest.snapshot!.phase, 'shooting');
    expect(guest.snapshot!.rows.length, 8);

    guest.shoot('h', 0, 0);
    guest.shoot('a', 0, 0); // чужой — не должен пройти
    await _settle();
    expect(c.stagedOf('h').length, 1);
    expect(c.stagedOf('a').length, 0);
    // Новое состояние с отметкой H уже у участника.
    expect(guest.snapshot!.row('h')!['staged'], isNotEmpty);
    guest.undo('h');
    await _settle();
    expect(c.stagedOf('h'), isEmpty);
    host.dispose();
  });

  test('права по ролям: хозяин, тренер и помощник — за всех, спортсмен — за себя; только принявшие', () {
    const members = [
      FinalsMember('s', 'coach1', FinalsRole.coach, null, 'Тренер', 'accepted'),
      FinalsMember('s', 'ath1', FinalsRole.athlete, 'a1', 'Спортсмен', 'accepted'),
      FinalsMember('s', 'help1', FinalsRole.helper, 'a2', 'Помощник', 'accepted'),
      FinalsMember('s', 'help2', FinalsRole.helper, 'a3', 'Не принял', 'invited'),
    ];
    expect(FinalsSessionService.scopeFor('host', 'host', members), isNull);
    expect(FinalsSessionService.scopeFor('coach1', 'host', members), isNull);
    expect(FinalsSessionService.scopeFor('ath1', 'host', members), {'a1'});
    expect(FinalsSessionService.scopeFor('help1', 'host', members), isNull); // помощник — за любого
    expect(FinalsSessionService.scopeFor('help2', 'host', members), isEmpty);
    expect(FinalsSessionService.scopeFor('stranger', 'host', members), isEmpty);
  });

  test('ручной режим: подготовка/заряжай/старт — кнопкой «Далее», команда тренера по сети', () async {
    final c = FinalRunController(
      format: FinalFormat.airRifle10m,
      face: TargetFace.rifle10m,
      engine: FinalEngine(FinalFormat.airRifle10m, [
        FinalCompetitor('a', 'A', isUser: true),
        for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i'),
      ]),
      userId: 'a',
      bots: {
        for (var i = 1; i <= 7; i++)
          'b$i': BotShooter(const ShotStats(0, 0, 3.0, 3.0, 100), BotDifficulty.medium, TargetFace.rifle10m, math.Random(i)),
      },
      rng: math.Random(1),
      manual: true,
    );
    // Время само не уводит дальше пристрелки.
    for (var i = 0; i < 400; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.sighting);
    expect(c.nextCommand, 'load');
    final (hostCh, coachCh) = MemoryFinalsChannel.pair();
    final host = FinalsHost(controller: c, channel: hostCh, allowed: (_) => null, canControl: (a) => a == 'coach');
    final coach = FinalsGuest(channel: coachCh, userId: 'coach');
    final stranger = FinalsGuest(channel: coachCh, userId: 'x');
    coach.next(); // → «Заряжай»
    await _settle();
    expect(c.phase, RunPhase.loading);
    for (var i = 0; i < 100; i++) {
      c.tick();
    }
    expect(c.phase, RunPhase.loading); // без «Старт» не стартует
    stranger.next(); // чужой — игнор
    await _settle();
    expect(c.phase, RunPhase.loading);
    coach.next(); // → «Старт»
    await _settle();
    expect(c.phase, RunPhase.shooting);
    expect(c.nextCommand, 'stop');
    host.dispose();
  });
}
