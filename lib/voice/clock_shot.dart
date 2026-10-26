import 'dart:math' as math;

import '../logic/scoring.dart';
import '../models/target_face.dart';

/// Точка попадания по словам «десять пять на пять часов»: результат [score] (например 10.5) и направление по циферблату
/// [hour] (12 — вверх, 3 — вправо, 6 — вниз, 9 — влево). Возвращает (x, y) в мм от центра, y вверх — как в мишени.
///
/// Расстояние от центра подбирается так, чтобы `scoreForPoint` дал именно этот результат (результат убывает с
/// расстоянием — поиск делением пополам), поэтому для любой мишени и любого калибра значение совпадает с названным.
(double x, double y) pointForScore(TargetFace face, double score, double hour) {
  final angle = (hour % 12) *
      30 *
      math.pi /
      180; // от направления вверх по часовой стрелке
  (double, double) at(double r) => (r * math.sin(angle), r * math.cos(angle));

  final maxR = face.faceRadiusMm;
  // Выше достижимого — в центр.
  if (scoreForPoint(0, 0, face) <= score + 1e-9) return (0, 0);
  // Ниже достижимого на мишени — на край листа.
  if (scoreForPoint(at(maxR).$1, at(maxR).$2, face) >= score) return at(maxR);

  var lo = 0.0, hi = maxR;
  for (var i = 0; i < 48; i++) {
    final mid = (lo + hi) / 2;
    final p = at(mid);
    if (scoreForPoint(p.$1, p.$2, face) >= score) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return at(lo);
}
