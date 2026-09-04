import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/shot.dart';
import '../models/target_face.dart';
import 'scoring.dart';

/// Аналитика по произвольному набору выстрелов.
///
/// Специально не привязана ни к тренировке, ни к упражнению: на вход —
/// просто список выстрелов и мишень, на которой они сделаны. Благодаря
/// этому один и тот же расчёт (и один и тот же блок графиков поверх
/// него) работает на всех срезах, которые попросил пользователь: все
/// тренировки, одно упражнение, одна тренировка, одна серия.
///
/// Всё считается лениво и кэшируется в полях — панель аналитики
/// обращается к одним и тем же величинам по несколько раз (плитки,
/// подписи, painter'ы), пересчитывать их каждый раз незачем.
class ShotAnalytics {
  final List<Shot> shots;
  final TargetFace face;

  ShotAnalytics(this.shots, this.face);

  bool get isEmpty => shots.isEmpty;
  int get count => shots.length;

  double? _total;

  /// Сумма очков.
  ///
  /// Намеренно обычным циклом, а не `fold`: в связке
  /// `_total ??= shots.fold(0.0, ...)` Dart выводил тип свёртки из
  /// НАЗНАЧЕНИЯ — то есть из nullable-поля `_total` — и аккумулятор
  /// становился `double?`, из-за чего `a + s.score` не компилировался.
  /// Цикл от такого вывода типов не зависит вовсе.
  double get total {
    final cached = _total;
    if (cached != null) return cached;
    var sum = 0.0;
    for (final s in shots) {
      sum += s.score;
    }
    return _total = sum;
  }

  double get average => shots.isEmpty ? 0 : total / shots.length;

  /// Сумма «целыми» — как её считают на большинстве соревнований, где
  /// десятые не идут в зачёт: 10.9 и 10.0 одинаково стоят десять очков.
  /// Рядом с десятичной суммой это сразу показывает, сколько стрелок
  /// «добирает» десятыми.
  int get totalWhole {
    var sum = 0;
    for (final s in shots) {
      sum += s.score.floor();
    }
    return sum;
  }

  double get best =>
      shots.isEmpty ? 0 : shots.map((s) => s.score).reduce((a, b) => a > b ? a : b);

  double get worst =>
      shots.isEmpty ? 0 : shots.map((s) => s.score).reduce((a, b) => a < b ? a : b);

  /// Количество выстрелов по целым габаритам: ключ 10..0, значение —
  /// сколько выстрелов. Ключи есть всегда все, включая нулевые, — иначе
  /// гистограмма "прыгала" бы, меняя число строк от среза к срезу.
  ///
  /// Габарит берётся как целая часть результата: 9.7 — это девятка.
  /// Отдельно 10.9 и 10.0 здесь не различаются намеренно — для этого
  /// есть средний результат и график динамики.
  Map<int, int> get ringCounts {
    final map = _ringCounts;
    if (map != null) return map;
    final result = {for (var ring = 10; ring >= 0; ring--) ring: 0};
    for (final s in shots) {
      final ring = s.score.floor().clamp(0, 10);
      result[ring] = (result[ring] ?? 0) + 1;
    }
    return _ringCounts = result;
  }

  Map<int, int>? _ringCounts;

  /// Сколько выстрелов попало в самый внутренний габарит — "десятки".
  int get tensCount => ringCounts[10] ?? 0;

  /// Все ли выстрелы легли в десятку.
  ///
  /// У мастера серия из десяти выстрелов «на 100» — обычное дело, и
  /// гистограмма по габаритам в этом случае вырождается в один столбик:
  /// смотреть не на что. Именно тогда (и только тогда) имеет смысл
  /// разложить десятку на десятые — там-то разница как раз и живёт.
  bool get allInTen => shots.isNotEmpty && tensCount == shots.length;

  /// Распределение внутри десятки: ключ 10..0 — это десятая доля
  /// (10 → 10.9, 0 → 10.0), значение — сколько выстрелов.
  ///
  /// Ключи идут от лучшего к худшему, как и в `ringCounts`, чтобы
  /// гистограмма рисовалась той же логикой сверху вниз.
  Map<int, int> get tenDecimalCounts {
    final cached = _tenDecimals;
    if (cached != null) return cached;
    final result = {for (var d = 9; d >= 0; d--) d: 0};
    for (final s in shots) {
      if (s.score < 10) continue;
      // 10.94 не бывает — шкала дискретна, но округление вниз всё равно
      // безопаснее: 10.9 попадает в 9, 10.0 — в 0.
      final d = ((s.score - 10) * 10 + 1e-9).floor().clamp(0, 9);
      result[d] = (result[d] ?? 0) + 1;
    }
    return _tenDecimals = result;
  }

  Map<int, int>? _tenDecimals;

  /// СТП — средняя точка попадания, мм от центра мишени.
  ///
  /// Это классический показатель разбора стрельбы: куда в среднем уходит
  /// оружие. Смещение СТП лечится поправкой прицела, а разброс вокруг
  /// СТП — техникой; поэтому их и считают отдельно.
  Offset get meanPoint {
    final p = _meanPoint;
    if (p != null) return p;
    if (shots.isEmpty) return _meanPoint = Offset.zero;
    var sx = 0.0;
    var sy = 0.0;
    for (final s in shots) {
      sx += s.xMm;
      sy += s.yMm;
    }
    return _meanPoint = Offset(sx / shots.length, sy / shots.length);
  }

  Offset? _meanPoint;

  /// Насколько СТП смещена от центра мишени, мм.
  double get meanOffsetMm => meanPoint.distance;

  /// Направление смещения СТП по мнемонике "часы" (12 — вверх).
  /// `null`, когда смещение меньше радиуса пробоины — на таком
  /// расстоянии направление уже не имеет смысла.
  int? get meanClock {
    if (shots.isEmpty) return null;
    if (meanOffsetMm < face.caliberRadiusMm) return null;
    return clockDirection(Shot(
      id: '_stp',
      shotNumber: 0,
      seriesNo: 0,
      xMm: meanPoint.dx,
      yMm: meanPoint.dy,
      score: 0,
      time: DateTime.fromMillisecondsSinceEpoch(0),
    ));
  }

  /// Кучность: средний радиус разброса относительно СТП, мм.
  ///
  /// Считается именно от СТП, а не от центра мишени: стрелок с ровной
  /// кучной группой, но сбитым прицелом должен видеть хорошую кучность
  /// и отдельно — смещение.
  double get groupMeanRadiusMm {
    final v = _groupMeanRadius;
    if (v != null) return v;
    if (shots.isEmpty) return _groupMeanRadius = 0;
    final c = meanPoint;
    var sum = 0.0;
    for (final s in shots) {
      sum += (Offset(s.xMm, s.yMm) - c).distance;
    }
    return _groupMeanRadius = sum / shots.length;
  }

  double? _groupMeanRadius;

  /// То же самое под общепринятым именем.
  ///
  /// В стрелковой практике эта величина называется «радиус СТП» (Mean
  /// Radius) — среднее расстояние от центра группы до пробоин. Прежняя
  /// подпись «средний разброс» была размытой: под разбросом одинаково
  /// понимают и это, и поперечник.
  double get meanRadiusMm => groupMeanRadiusMm;

  /// Поперечник группы (extreme spread) — расстояние между двумя самыми
  /// далёкими друг от друга пробоинами, мм.
  ///
  /// Считается перебором пар, то есть O(n²). На срезе "все тренировки"
  /// выстрелов могут быть тысячи, и перебор заметно подвесил бы UI,
  /// поэтому выше порога возвращается `null`, а панель показывает
  /// прочерк с пояснением — это честнее, чем тихо считать по обрезанной
  /// выборке и выдавать неверное число за настоящее.
  static const int extremeSpreadLimit = 400;

  double? get extremeSpreadMm {
    if (shots.length < 2 || shots.length > extremeSpreadLimit) return null;
    final cached = _extremeSpread;
    if (cached != null) return cached;
    var maxD = 0.0;
    for (var i = 0; i < shots.length; i++) {
      for (var j = i + 1; j < shots.length; j++) {
        final dx = shots[i].xMm - shots[j].xMm;
        final dy = shots[i].yMm - shots[j].yMm;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > maxD) maxD = d;
      }
    }
    return _extremeSpread = maxD;
  }

  double? _extremeSpread;

  /// Пара самых далёких друг от друга пробоин.
  ///
  /// Нужна не сама по себе, а чтобы нарисовать окружность максимального
  /// рассеивания: она строится на этой паре как на диаметре. Считается
  /// тем же перебором, что и поперечник, и с тем же ограничением.
  (Shot, Shot)? get extremePair {
    if (shots.length < 2 || shots.length > extremeSpreadLimit) return null;
    final cached = _extremePair;
    if (cached != null) return cached;
    var maxD = -1.0;
    Shot? a;
    Shot? b;
    for (var i = 0; i < shots.length; i++) {
      for (var j = i + 1; j < shots.length; j++) {
        final dx = shots[i].xMm - shots[j].xMm;
        final dy = shots[i].yMm - shots[j].yMm;
        final d = dx * dx + dy * dy; // корень не нужен: сравниваем между собой
        if (d > maxD) {
          maxD = d;
          a = shots[i];
          b = shots[j];
        }
      }
    }
    if (a == null || b == null) return null;
    return _extremePair = (a, b);
  }

  (Shot, Shot)? _extremePair;

  /// Центр окружности максимального рассеивания — середина отрезка между
  /// двумя самыми далёкими пробоинами.
  ///
  /// Это НЕ минимальная объемлющая окружность (её центр в общем случае
  /// другой, и часть пробоин у такой окружности может остаться снаружи).
  /// Пользователь просил именно круг «проходящий через две самые дальние
  /// пробоины» — он наглядно показывает поперечник, и это его роль.
  Offset? get spreadCircleCenterMm {
    final pair = extremePair;
    if (pair == null) return null;
    return Offset(
      (pair.$1.xMm + pair.$2.xMm) / 2,
      (pair.$1.yMm + pair.$2.yMm) / 2,
    );
  }

  /// Радиусы, внутрь которых от СТП попадает заданная доля выстрелов.
  ///
  /// Это круговая вероятная ошибка (CEP): при доле 0.5 — половина
  /// выстрелов, при 0.9 — девять из десяти. Смысл в том, чтобы увидеть
  /// настоящую кучность без одиночных отрывов: один вылетевший выстрел
  /// поднимает поперечник вдвое, а на радиус половины попаданий не
  /// влияет вовсе.
  ///
  /// Берётся по фактическим расстояниям, а не по нормальному
  /// распределению: выборка в 10–60 выстрелов слишком мала, чтобы
  /// подгонка эллипса давала что-то честнее простого порядкового
  /// значения.
  double? cepRadiusMm(double fraction) {
    if (shots.length < 4) return null; // на трёх выстрелах это шум
    final d = _sortedDistances;
    // Индекс порядковой статистики: доля 0.5 при 10 выстрелах — пятый.
    var idx = (d.length * fraction).ceil() - 1;
    if (idx < 0) idx = 0;
    if (idx >= d.length) idx = d.length - 1;
    return d[idx];
  }

  List<double> get _sortedDistances {
    final cached = _distances;
    if (cached != null) return cached;
    final c = meanPoint;
    final list = [for (final s in shots) (Offset(s.xMm, s.yMm) - c).distance]..sort();
    return _distances = list;
  }

  List<double>? _distances;

  /// Разброс по направлениям: 12 корзин, индекс 0 — 12 часов, далее по
  /// часовой стрелке (индекс 3 — 3 часа).
  ///
  /// Выстрелы, легшие практически в центр (ближе радиуса пробоины),
  /// в розу не попадают: у них направление — это шум округления, а не
  /// снос, и они бы только размазывали картину.
  List<int> get clockCounts {
    final cached = _clockCounts;
    if (cached != null) return cached;
    final result = List<int>.filled(12, 0);
    for (final s in shots) {
      if (s.radiusMm < face.caliberRadiusMm) continue;
      final hour = clockDirection(s); // 1..12, 12 — вверх
      result[hour % 12] += 1;
    }
    return _clockCounts = result;
  }

  List<int>? _clockCounts;

  /// Сколько выстрелов учтено в розе направлений (без центральных).
  int get directionalCount => clockCounts.fold(0, (a, b) => a + b);

  /// Сводка по сериям, в порядке возрастания номера серии.
  List<SeriesStat> get seriesStats {
    final cached = _seriesStats;
    if (cached != null) return cached;
    final grouped = <int, List<Shot>>{};
    for (final s in shots) {
      grouped.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final keys = grouped.keys.toList()..sort();
    return _seriesStats = [
      for (final k in keys)
        SeriesStat(
          seriesNo: k,
          count: grouped[k]!.length,
          total: grouped[k]!.fold(0.0, (a, s) => a + s.score),
        ),
    ];
  }

  List<SeriesStat>? _seriesStats;
}

/// Название направления смещения по восьми румбам.
///
/// «Смещение СТП: 0.1 мм» без направления бесполезно — непонятно, куда
/// крутить барабанчики. Восемь румбов, а не двенадцать часов: словами
/// «вверх-вправо» читается сразу, а «на 2 часа» требует перевода.
///
/// `null` — смещения фактически нет.
String? directionName(Offset mm, {double deadZoneMm = 0.05}) {
  if (mm.distance < deadZoneMm) return null;
  // Угол от оси «вверх», по часовой стрелке. Y в мм направлена вверх.
  var deg = math.atan2(mm.dx, mm.dy) * 180 / math.pi;
  if (deg < 0) deg += 360;
  const names = [
    'вверх',
    'вверх-вправо',
    'вправо',
    'вниз-вправо',
    'вниз',
    'вниз-влево',
    'влево',
    'вверх-влево',
  ];
  return names[(((deg + 22.5) % 360) / 45).floor() % 8];
}

/// Стрелка в сторону смещения — те же восемь румбов, что и
/// [directionName], но одним знаком: рядом с «−0.2 / +0.1» слово не
/// помещается, а стрелка читается мгновенно.
String? directionArrow(Offset mm, {double deadZoneMm = 0.05}) {
  if (mm.distance < deadZoneMm) return null;
  var deg = math.atan2(mm.dx, mm.dy) * 180 / math.pi;
  if (deg < 0) deg += 360;
  const arrows = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖'];
  return arrows[(((deg + 22.5) % 360) / 45).floor() % 8];
}

/// Низ шкалы графика: на один шаг ниже худшего значения, но не ниже
/// нуля.
///
/// График, начинающийся с нуля, у стрелка уровня мастера бесполезен:
/// все точки лежат между 9 и 10.9, линия жмётся к верхнему краю и
/// выглядит идеально ровной. Подрезанная снизу шкала показывает ровно
/// ту разницу, ради которой на график и смотрят. Ноль остаётся нулём:
/// промах — это дно шкалы, ниже некуда.
double axisMin(Iterable<double> values, {double step = 1}) {
  if (values.isEmpty) return 0;
  var min = values.first;
  for (final v in values) {
    if (v < min) min = v;
  }
  final floored = (min / step).floor() * step - step;
  return floored < 0 ? 0 : floored;
}

/// Округление верха шкалы графика до "круглого" числа, чтобы подписи
/// делений читались: 109 → 150 (шаг 30 при пяти делениях), а не 109 с
/// шагом 21.8.
double niceMax(double v) {
  if (v <= 0) return 10;
  final exponent = (math.log(v) / math.ln10).floor();
  final magnitude = math.pow(10, exponent).toDouble();
  for (final m in const [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]) {
    if (v <= magnitude * m + 1e-9) return magnitude * m;
  }
  return magnitude * 10;
}

/// Итог одной серии.
class SeriesStat {
  final int seriesNo;
  final int count;
  final double total;

  const SeriesStat({
    required this.seriesNo,
    required this.count,
    required this.total,
  });

  double get average => count == 0 ? 0 : total / count;
}
