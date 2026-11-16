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

  /// Ручная настройка: мин/макс выстрел, STP, направление разброса.
  manual,
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
  
  /// Ручной режим параметры
  final double? manualMinShot;
  final double? manualMaxShot;
  final double? manualStp;
  final double? manualDispersionDeg;
  
  late final ShotStats _active = _pick();

  BotShooter(this.stats, this.difficulty, this.face, this.rng, {this.sessions = const [], 
    this.manualMinShot, this.manualMaxShot, this.manualStp, this.manualDispersionDeg});

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
        BotDifficulty.manual => (1.0, 1.0), // не используется в ручном режиме
      };

  double _gauss() {
    // Бокс — Мюллер.
    final u1 = 1 - rng.nextDouble(), u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// «Форма» бота: полоса удач и неудач (серии держатся несколько выстрелов).
  /// > 0 — бот в удаче (кучнее и ближе к центру), < 0 — сыпется.
  double form = 0;
  
  /// Счётчик выстрелов для STP (выстрелов к пику)
  int _shotCount = 0;

  /// Один выстрел: точка (x, y) в мм. [volatility] 0…1 — сила камбэков:
  /// форма бота плавает вверх и вниз, из-за чего он может подняться или упасть
  /// по таблице; при 0 бот стреляет ровно по своей статистике.
  (double, double) shotPoint({double volatility = 0}) {
    // Ручной режим: используем заданные параметры
    if (difficulty == BotDifficulty.manual && manualMinShot != null && manualMaxShot != null) {
      _shotCount++;
      // STP: плавное приближение к лучшему результату
      double stpFactor = 1.0;
      if (manualStp != null && manualStp! > 0) {
        stpFactor = (_shotCount / manualStp!).clamp(0.0, 1.0);
      }
      
      // Интерполируем между мин и макс значением выстрела
      final targetScore = manualMinShot! + (manualMaxShot! - manualMinShot!) * stpFactor;
      
      // Направление разброса
      double angleRad = 0;
      if (manualDispersionDeg != null) {
        angleRad = manualDispersionDeg! * math.pi / 180.0;
      }
      
      // Вычисляем радиус для целевого результата через обратную функцию подсчёта
      final ring = targetScore.floor().clamp(0, 10);
      final decimal = ((targetScore - ring) * 10).round().clamp(0, 9);
      final radius = radiusForScore(ring, decimal, face);
      
      // Разброс вокруг целевого радиуса
      final spread = face.ringWidthMm * 0.3; // ~30% ширины кольца
      final r = radius + _gauss() * spread;
      final a = angleRad + _gauss() * 0.3;
      
      return (r * math.cos(a), r * math.sin(a));
    }
    
    final (mpi, disp) = _scales;
    form = (0.7 * form + 0.6 * volatility * _gauss()).clamp(-1.5, 1.5);
    final dm = math.exp(-0.22 * form); // разброс
    final bm = math.exp(-0.3 * form); // смещение СТП
    return (
      mpi * bm * _active.mx + disp * dm * _active.sx * _gauss(),
      mpi * bm * _active.my + disp * dm * _active.sy * _gauss(),
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
