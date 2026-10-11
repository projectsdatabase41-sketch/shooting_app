import 'dart:math' as math;

/// Проверка правдоподобия финала: средний балл выстрела в финале против
/// распределения тренировок на той же мишени. Только «слишком хорошо»
/// (z > [maxZ]) считается подозрительным; мало данных — не судим.
enum Plausibility { ok, suspicious, unknown }

Plausibility checkPlausibility(List<double> training, List<double> finalShots, {double maxZ = 3.0}) {
  if (training.length < 30 || finalShots.length < 10) return Plausibility.unknown;
  final mu = training.reduce((a, b) => a + b) / training.length;
  final varr = training.map((v) => (v - mu) * (v - mu)).reduce((a, b) => a + b) / (training.length - 1);
  final sd = math.max(math.sqrt(varr), 0.05);
  final avg = finalShots.reduce((a, b) => a + b) / finalShots.length;
  final z = (avg - mu) / (sd / math.sqrt(finalShots.length));
  return z > maxZ ? Plausibility.suspicious : Plausibility.ok;
}
