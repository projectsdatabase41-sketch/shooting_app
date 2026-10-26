import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/announcer.dart';
import 'package:shooting_app/finals/bot.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/models/target_face.dart';

FinalRunController _make({bool manual = false, FinalFormat format = FinalFormat.airRifle10m}) {
  final face = TargetFace.byCode(format.faceCode);
  const stats = ShotStats(0.5, -0.5, 3.0, 3.0, 100);
  return FinalRunController(
    format: format,
    face: face,
    engine: FinalEngine(format, [FinalCompetitor('me', 'Я', isUser: true), for (var i = 1; i <= 7; i++) FinalCompetitor('b$i', 'Бот $i')]),
    userId: 'me',
    bots: {for (var i = 1; i <= 7; i++) 'b$i': BotShooter(stats, BotDifficulty.medium, face, math.Random(i))},
    rng: math.Random(1),
    manual: manual,
  );
}

/// Команды диктора за весь финал: на каждый этап «стрельба» должны быть «Заряжай» перед ним и «Старт» на нём.
List<String> _commands(FinalRunController c, {bool manual = false}) {
  final v = PhaseAnnouncer();
  final out = <String>[];
  void feed() {
    final s = v.update(c.phase.name, secondsLeft: c.secondsLeft, announcing: c.announcing);
    if (s != null) out.add(s);
  }

  feed();
  var n = 0;
  while (c.phase != RunPhase.finished && n++ < 30000) {
    while (c.userCanShoot) {
      c.submitUserShot(0, 0);
    }
    if (manual && c.phase != RunPhase.shooting) {
      c.advance();
    } else {
      c.tick();
    }
    feed();
  }
  return out;
}

void main() {
  for (final manual in [false, true]) {
    test('«Заряжай» и «Старт» перед каждым раундом, включая одиночные (manual=$manual)', () {
      final cmds = _commands(_make(manual: manual), manual: manual);
      var starts = 0;
      for (var i = 0; i < cmds.length; i++) {
        if (cmds[i] == 'Старт.') {
          starts++;
          expect(cmds[i - 1], 'Заряжай.', reason: 'перед «Старт» №$starts нет «Заряжай»: $cmds');
        }
      }
      expect(starts, greaterThanOrEqualTo(5 + 1), reason: '$cmds');
    });
  }
}
