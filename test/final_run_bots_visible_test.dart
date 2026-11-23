import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/painters/target_painter.dart';
import 'package:shooting_app/screens/final_run_screen.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  // Отзыв владельца 23.11 №1/№2: мишени соперников убраны с личного монитора
  // (там свой список выстрелов), а все мишени целиком переехали на вид «Табло»
  // (кнопка в шапке). Именно это и проверяем.
  testWidgets('на мониторе не видно мишеней соперников, на табло видны все', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    final face = TargetFace.rifle10m;
    final c = FinalRunController(
      format: FinalFormat.airRifle10m,
      face: face,
      engine: FinalEngine(FinalFormat.airRifle10m, [
        FinalCompetitor('me', 'Я', isUser: true),
        for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i'),
      ]),
      userId: 'me',
      bots: {for (var i = 1; i <= 7; i++) 'b$i': BotShooter(const ShotStats(0, 0, 3, 3, 100), BotDifficulty.medium, face, math.Random(i))},
      rng: math.Random(1),
    );
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(ChangeNotifierProvider<AppDataStore>.value(
      value: store,
      child: MaterialApp(home: FinalRunScreen(controller: c, store: store)),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    Iterable<TargetPainter> painters() =>
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((p) => p.painter).whereType<TargetPainter>();
    // Личный монитор: только своя мишень.
    expect(painters().length, 1);
    // У ботов должны появиться пробоины: иначе на табло корректно нет
    // миниатюр («если есть данные — иначе только таблица»).
    c.skipSighting();
    var ticks = 0;
    while (c.shots.length < 25 && ticks < 20000) {
      while (c.userCanShoot) {
        c.submitUserShot(0, -5); // свой выстрел: миниатюра и на моей строке
      }
      for (final id in c.missingIds) {
        while (c.canShootFor(id)) {
          c.markMiss(id);
        }
      }
      c.tick();
      ticks++;
    }
    await tester.pump(const Duration(milliseconds: 300));
    // Переключаемся на табло кнопкой в шапке (иконка «Табло зрителей»).
    await tester.tap(find.byIcon(Icons.tv));
    await tester.pump(const Duration(milliseconds: 300));
    // На табло: 7 соперников + своя мишень.
    expect(painters().length, greaterThanOrEqualTo(8));
  });
}
