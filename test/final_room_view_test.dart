import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/finals/finals_net.dart';
import 'package:shooting_app/finals/finals_session_service.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/screens/final_room_screens.dart';

FinalRunController _c() {
  final face = TargetFace.rifle10m;
  return FinalRunController(
    format: FinalFormat.airRifle10m,
    face: face,
    engine: FinalEngine(FinalFormat.airRifle10m, [
      FinalCompetitor('a', 'Анна'),
      FinalCompetitor('h', 'Игорь'),
      for (var i = 1; i <= 6; i++) FinalCompetitor('b$i', 'Бот $i (Bot)'),
    ]),
    userId: 'a',
    otherHumans: {'h'},
    bots: {for (var i = 1; i <= 6; i++) 'b$i': BotShooter(const ShotStats(0, 0, 3, 3, 100), BotDifficulty.medium, face, math.Random(i))},
    rng: math.Random(1),
    manual: true,
  );
}

void main() {
  testWidgets('тренер видит кнопку команды и ввод за людей; спортсмен — свою мишень', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _c();
    var next = 0;
    await tester.pumpWidget(MaterialApp(
      home: FinalRoomView(
        snapshot: FinalsSnapshot.of(c),
        role: FinalsRole.coach,
        onShoot: (_, __) {},
        onUndo: (_) {},
        onNext: () => next++,
      ),
    ));
    expect(find.text('Заряжай'), findsOneWidget);
    await tester.tap(find.text('Заряжай'));
    expect(next, 1);
    expect(find.text('Судья'), findsWidgets); // подпись роли внизу
    expect(find.byIcon(Icons.gps_fixed), findsNothing); // ввод — на странице, без выезжающих окон

    await tester.pumpWidget(MaterialApp(
      home: FinalRoomView(
        snapshot: FinalsSnapshot.of(c),
        role: FinalsRole.athlete,
        ownId: 'a',
        onShoot: (_, __) {},
        onUndo: (_) {},
      ),
    ));
    expect(find.text('Назад'), findsOneWidget);
    expect(find.text('Участник · Анна'), findsOneWidget);
  });

  testWidgets('несколько тиров: у каждого виден статус связи и тир у участника', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _c()
      ..sites = {'a': '1', 'h': '2'}
      ..siteStatus = {'1': [2, 2], '2': [1, 3]};
    await tester.pumpWidget(MaterialApp(
      home: FinalRoomView(snapshot: FinalsSnapshot.of(c), role: FinalsRole.coach, onShoot: (_, __) {}, onUndo: (_) {}),
    ));
    expect(find.text('Тир 1: 2/2'), findsOneWidget);
    expect(find.text('Тир 2: 1/3'), findsOneWidget);
  });
}
