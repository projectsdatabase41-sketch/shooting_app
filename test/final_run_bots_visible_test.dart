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
  testWidgets('мишени соперников видны, пока выстрелов ещё нет', (tester) async {
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
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(ChangeNotifierProvider<AppDataStore>.value(
      value: store,
      child: MaterialApp(home: FinalRunScreen(controller: c, store: store)),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where((p) => p.painter is TargetPainter).toList();
    // 7 соперников + моя мишень (стартовая раскладка: 3 сверху, остальные внизу сеткой)
    expect(painters.length, greaterThanOrEqualTo(8));
    c.dispose();
  });
}
