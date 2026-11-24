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

  /// Ручной режим: мин/макс выстрел, STP, направление разброса.
  manual,

  /// Авто (по умолчанию, отзыв владельца 24.11): статистику и уровень бот
  /// берёт из тренировок спортсмена по этой мишени и изготовке (средний
  /// результат бота калибруется под средний результат спортсмена), а если
  /// тренировок мало — из разряда профиля и нормативной таблицы
  /// (`rank_norms.dart`). Множители сложности не применяются.
  auto,
}

/// Коды изготовок ботов (отзыв владельца 24.11): фильтр истории тренировок и
/// отдельная статистика по положениям в финале 3P.
const String stanceProne = 'prone'; // лёжа
const String stanceKneeling = 'kneeling'; // с колена
const String stanceStanding = 'standing'; // стоя

/// Изготовка по названию упражнения: «лёжа», «с колена»/«колено», «стоя».
/// В названии нет изготовки — `null` (история не фильтруется по изготовке).
String? stanceFromName(String name) {
  final s = name.toLowerCase();
  if (s.contains('лёж')) return stanceProne;
  if (s.contains('колен')) return stanceKneeling;
  if (s.contains('стоя') || s.contains('стойк')) return stanceStanding;
  return null;
}

/// Этап ожидания бота перед выстрелом (отзыв владельца 24.11): пауза между
/// выстрелами — не плоская задержка, а стадии «отдых», «прицеливание»,
/// «перезарядка», каждая стоит времени и видна в статусе бота.
enum BotStage { rest, aim, reload }

/// Длительности этапов одного выстрела бота (в секундах симуляции).
class BotStagePlan {
  final int rest;
  final int aim;
  final int reload;
  const BotStagePlan(this.rest, this.aim, this.reload);

  /// Полное время от конца предыдущего выстрела до следующего.
  int get total => rest + aim + reload;
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

  /// Статистика по отдельным изготовкам для 3P (отзыв владельца 24.11):
  /// в финале из трёх положений бот стреляет по каждой изготовке своим
  /// уровнем. Ключ — код изготовки (`stanceProne`, `stanceKneeling`,
  /// `stanceStanding`). Пусто — общий уровень [stats].
  final Map<String, ShotStats> byStance;

  /// Текущая изготовка; контроллер финала меняет её при смене положения
  /// (в 3P с колена → лёжа → стоя).
  String? stance;

  BotShooter(this.stats, this.difficulty, this.face, this.rng,
      {this.sessions = const [],
      this.manualMinShot,
      this.manualMaxShot,
      this.manualStp,
      this.manualDispersionDeg,
      this.byStance = const {}});

  /// Статистика для текущего выстрела: «непредсказуемый» каждый финал —
  /// случайная тренировка; при заданной изготовке — её статистика.
  ShotStats _pick() {
    if (difficulty == BotDifficulty.unpredictable && sessions.isNotEmpty) {
      return sessions[rng.nextInt(sessions.length)];
    }
    final s = byStance[stance];
    return s ?? stats;
  }

  /// (смещение СТП, разброс) для сложности; у «непредсказуемого» — случайно.
  /// «Авто» — множители не применяются: калибровка под среднего спортсмена
  /// уже сделана при создании бота (см. [calibrated]).
  (double, double) get _scales => switch (difficulty) {
        BotDifficulty.easy => (1.35, 1.18),
        BotDifficulty.medium => (1.0, 1.0),
        BotDifficulty.hard => (0.65, 0.88),
        BotDifficulty.unpredictable => (0.6 + rng.nextDouble() * 0.9, 0.8 + rng.nextDouble() * 0.45),
        BotDifficulty.auto => (1.0, 1.0),
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
    final act = _pick(); // один выбор на выстрел: СТП и разброс из одной статистики
    return (
      mpi * bm * act.mx + disp * dm * act.sx * _gauss(),
      mpi * bm * act.my + disp * dm * act.sy * _gauss(),
    );
  }

  /// Детерминированные квантили стандартного нормального распределения.
  /// Нужны для калибровки без случайности: средний результат бота оценивается
  /// по фиксированной решётке, поэтому одинаков у всех ботов и воспроизводим
  /// в тестах.
  static const _quantiles = [
    -2.054, -1.5, -1.1, -0.8, -0.55, -0.32, -0.1, 0.1, 0.32, 0.55, 0.8, 1.1, 1.5, 2.054,
  ];

  /// Средний результат бота со статистикой [st] без «формы» и случайности —
  /// по той же формуле `shotPoint`, но по детерминированной решётке квантилей.
  static double meanScoreFor(ShotStats st, TargetFace face) {
    var sum = 0.0;
    for (final zx in _quantiles) {
      for (final zy in _quantiles) {
        sum += scoreForPoint(st.mx + st.sx * zx, st.my + st.sy * zy, face);
      }
    }
    return sum / (_quantiles.length * _quantiles.length);
  }

  /// Статистика бота «под средний результат» (отзыв владельца 24.11):
  /// одним множителем масштабируются и СТП, и разброс исходной статистики
  /// [base] так, чтобы средний выстрел бота был равен [targetAvg] — среднему
  /// результату спортсмена в тренировках. Без этого обычные множители давали
  /// не «соперника того же уровня», а случайно слабого бота (3–5 очков).
  static ShotStats calibrated(ShotStats base, double targetAvg, TargetFace face) {
    if (targetAvg <= 0 || targetAvg >= face.maxScore || base.sx <= 0 || base.sy <= 0) {
      return base;
    }
    ShotStats apply(double k) =>
        ShotStats(base.mx * k, base.my * k, base.sx * k, base.sy * k, base.n);
    // Чем больше множитель, тем хуже стреляет бот — ищем им бисекцией.
    var lo = 0.05, hi = 4.0;
    if (meanScoreFor(apply(lo), face) <= targetAvg) return apply(lo);
    if (meanScoreFor(apply(hi), face) >= targetAvg) return apply(hi);
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (meanScoreFor(apply(mid), face) > targetAvg) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return apply((lo + hi) / 2);
  }

  /// Статистика бота по среднему [avg] и разбросу [sdPoints] в очках —
  /// из нормативной таблицы (`rank_norms.dart`, отзыв владельца 24.11):
  /// центр в нуле, σ очков переводится в миллиметры по цене десятой доли
  /// мишени (0.1 очка = `decimalStepMm` мм), затем ровно так же калибруется
  /// под средний результат, как и статистика тренировок.
  static ShotStats forAverage(double avg, double sdPoints, TargetFace face) {
    final sigma = (sdPoints * 10 * face.decimalStepMm).clamp(0.1, face.faceRadiusMm).toDouble();
    final target = avg.clamp(0.1, face.maxScore - 0.05).toDouble();
    return calibrated(ShotStats(0, 0, sigma, sigma, 1), target, face);
  }
  
  /// Один выстрел: результат с десятыми по правилам мишени.
  double nextScore() {
    final (x, y) = shotPoint();
    return scoreForPoint(x, y, face);
  }

  /// Через сколько секунд бот выстрелит, если на выстрел дано [limitSeconds].
  ///
  /// Не быстрее, чем раз в 4 секунды: человеку нужно перезарядить винтовку,
  /// встать в изготовку и прицелиться — по отзыву 17.11 это «не менее 5 секунд».
  /// Медленнее — можно (до лимита на выстрел), быстрее — нельзя.
  ///
  /// Живой план пауз ботов — [stagePause] с разбиением на «отдых/прицеливание/
  /// перезарядку» (отзыв владельца 24.11); метод оставлен для совместимости
  /// (используется старыми тестами).
  double delaySeconds(int limitSeconds) {
    final base = limitSeconds * (0.35 + rng.nextDouble() * 0.5);
    final atLeastHuman = math.max(4.0, base);
    return math.min(limitSeconds.toDouble(), atLeastHuman);
  }

  /// Диапазоны этапов паузы бота (отзыв владельца 24.11):
  /// винтовка — отдых 4–9 с, прицеливание 3–7 с, перезарядка 2–4 с;
  /// пистолет — 2–5 / 2–4 / 1–2 с. Смена положения и пристрелка между сериями
  /// 3P учитываются отдельно (`FinalFormat.changeAfterSeries`).
  static const List<(int, int)> _rifleStages = [(4, 9), (3, 7), (2, 4)];
  static const List<(int, int)> _pistolStages = [(2, 5), (2, 4), (1, 2)];

  bool get isRifle => face.code.startsWith('rifle');

  /// План стадий перед одним выстрелом: отдых → прицеливание → перезарядка →
  /// выстрел. [slotSeconds] — слот этого выстрела в раунде: сумма стадий не
  /// превышает его; если слот меньше (свой формат с плотной сеткой), стадии
  /// пропорционально сжимаются (но не короче секунды каждая). Контроллер
  /// дополнительно держит зазор между выстрелами не меньше 5 с.
  BotStagePlan stagePause(int slotSeconds) {
    final ranges = isRifle ? _rifleStages : _pistolStages;
    int pick((int, int) r) => r.$1 + rng.nextInt(r.$2 - r.$1 + 1);
    var rest = pick(ranges[0]), aim = pick(ranges[1]), reload = pick(ranges[2]);
    final total = rest + aim + reload;
    if (slotSeconds > 0 && total > slotSeconds) {
      final k = slotSeconds / total;
      rest = math.max(1, (rest * k).floor());
      aim = math.max(1, (aim * k).floor());
      reload = math.max(1, (reload * k).floor());
    }
    return BotStagePlan(rest, aim, reload);
  }
}
