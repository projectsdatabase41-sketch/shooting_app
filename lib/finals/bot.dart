import 'dart:math' as math;

import '../logic/scoring.dart';
import '../models/target_face.dart';

/// Статистика выстрелов спортсмена: средняя точка попадания (СТП) в мм от
/// центра (с направлением смещения) и разброс по осям. Число выстрелов в
/// расчёте не учитывается — сравнивается только манера стрельбы.
class ShotStats {
  final double mx;
  final double my;
  final double sx;
  final double sy;
  final int n;
  const ShotStats(this.mx, this.my, this.sx, this.sy, this.n);

  /// Из координат выстрелов (x вправо, y вверх, мм). [robust] отбрасывает
  /// редкие «отрывные» выстрелы (дальше среднего расстояния + 2σ).
  factory ShotStats.fromPoints(List<(double, double)> pts, {bool robust = false}) {
    if (pts.isEmpty) return const ShotStats(0, 0, 1, 1, 0);
    var use = pts;
    if (robust && pts.length >= 8) {
      final c = _calc(pts);
      final ds = [for (final p in pts) math.sqrt(math.pow(p.$1 - c.mx, 2) + math.pow(p.$2 - c.my, 2))];
      final mean = ds.reduce((a, b) => a + b) / ds.length;
      final sd = math.sqrt(ds.map((d) => math.pow(d - mean, 2)).reduce((a, b) => a + b) / ds.length);
      final limit = mean + 2 * sd;
      final kept = [for (var i = 0; i < pts.length; i++) if (ds[i] <= limit) pts[i]];
      if (kept.length >= 5) use = kept;
    }
    return _calc(use);
  }

  static ShotStats _calc(List<(double, double)> pts) {
    final n = pts.length;
    final mx = pts.map((p) => p.$1).reduce((a, b) => a + b) / n;
    final my = pts.map((p) => p.$2).reduce((a, b) => a + b) / n;
    double sd(double Function((double, double)) f, double mean) => n < 2
        ? 1
        : math.max(0.3, math.sqrt(pts.map((p) => math.pow(f(p) - mean, 2)).reduce((a, b) => a + b) / (n - 1)));
    return ShotStats(mx, my, sd((p) => p.$1, mx), sd((p) => p.$2, my), n);
  }
}

/// Сложность бота: насколько он стреляет лучше или хуже среднего спортсмена.
enum BotDifficulty {
  /// Чуть хуже среднего (СТП смещена дальше от центра, разброс больше).
  easy,

  /// Как сам спортсмен.
  medium,

  /// Чуть лучше среднего.
  hard,

  /// Каждый финал — одна случайная тренировка, и случайные колебания.
  unpredictable,
}

/// Бот: стреляет настоящими выстрелами (точка попадания), которые считаются
/// обычным подсчётом очков мишени, — как у человека.
class BotShooter {
  final ShotStats stats;
  final BotDifficulty difficulty;
  final TargetFace face;
  final math.Random rng;

  /// Для «непредсказуемого»: статистика отдельных тренировок спортсмена.
  final List<ShotStats> sessions;
  late final ShotStats _active = _pick();

  BotShooter(this.stats, this.difficulty, this.face, this.rng, {this.sessions = const []});

  ShotStats _pick() {
    if (difficulty != BotDifficulty.unpredictable || sessions.isEmpty) return stats;
    return sessions[rng.nextInt(sessions.length)];
  }

  /// (смещение СТП, разброс) для сложности; у «непредсказуемого» — случайно.
  (double, double) get _scales => switch (difficulty) {
        BotDifficulty.easy => (1.35, 1.18),
        BotDifficulty.medium => (1.0, 1.0),
        BotDifficulty.hard => (0.65, 0.88),
        BotDifficulty.unpredictable => (0.6 + rng.nextDouble() * 0.9, 0.8 + rng.nextDouble() * 0.45),
      };

  double _gauss() {
    // Бокс — Мюллер.
    final u1 = 1 - rng.nextDouble(), u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// Один выстрел: точка (x, y) в мм.
  (double, double) shotPoint() {
    final (mpi, disp) = _scales;
    return (
      mpi * _active.mx + disp * _active.sx * _gauss(),
      mpi * _active.my + disp * _active.sy * _gauss(),
    );
  }

  /// Один выстрел: результат с десятыми по правилам мишени.
  double nextScore() {
    final (x, y) = shotPoint();
    return scoreForPoint(x, y, face);
  }

  /// Через сколько секунд бот выстрелит, если на выстрел дано [limitSeconds]
  /// (человек стреляет не мгновенно и не на последней секунде).
  double delaySeconds(int limitSeconds) => limitSeconds * (0.3 + rng.nextDouble() * 0.55);
}
