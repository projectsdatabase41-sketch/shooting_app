import 'dart:math' as math;
import 'dart:typed_data';

/// Изображение в градациях серого — минимальный формат для этого файла,
/// не завязанный на `package:image` (тот нужен только для декодирования
/// самого JPEG/PNG, что делает вызывающий код в `services/`). Здесь —
/// чистая геометрия и арифметика, которую можно проверить синтетическими
/// картинками без камеры и без реального файла.
class GrayImage {
  final int width;
  final int height;
  final Uint8List pixels; // yValue = pixels[y*width+x], 0..255

  GrayImage(this.width, this.height, this.pixels);

  factory GrayImage.filled(int width, int height, int value) =>
      GrayImage(width, height, Uint8List(width * height)..fillRange(0, width * height, value));

  int at(int x, int y) => pixels[y * width + x];
  void set(int x, int y, int v) => pixels[y * width + x] = v.clamp(0, 255);

  /// Рисует закрашенный круг — только для тестов (синтетические мишени
  /// и пробоины).
  void fillCircle(double cx, double cy, double r, int value) {
    final x0 = math.max(0, (cx - r).floor());
    final x1 = math.min(width - 1, (cx + r).ceil());
    final y0 = math.max(0, (cy - r).floor());
    final y1 = math.min(height - 1, (cy + r).ceil());
    final r2 = r * r;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = x + 0.5 - cx;
        final dy = y + 0.5 - cy;
        if (dx * dx + dy * dy <= r2) set(x, y, value);
      }
    }
  }

  /// Рисует кольцо (контур) заданной толщины — только для тестов:
  /// имитирует напечатанные кольца мишени, в отличие от `fillCircle`
  /// (сплошное пятно, имитирует пробоину).
  void fillRing(double cx, double cy, double radius, double thickness, int value) {
    final r0 = radius - thickness / 2, r1 = radius + thickness / 2;
    final x0 = math.max(0, (cx - r1).floor());
    final x1 = math.min(width - 1, (cx + r1).ceil());
    final y0 = math.max(0, (cy - r1).floor());
    final y1 = math.min(height - 1, (cy + r1).ceil());
    final r0sq = r0 * r0, r1sq = r1 * r1;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = x + 0.5 - cx;
        final dy = y + 0.5 - cy;
        final d2 = dx * dx + dy * dy;
        if (d2 >= r0sq && d2 <= r1sq) set(x, y, value);
      }
    }
  }
}

/// Простое целочисленное смещение в пикселях исходного изображения.
class PixelPoint {
  final double x;
  final double y;
  const PixelPoint(this.x, this.y);
}

/// Один найденный кандидат в пробоину.
class HoleCandidate {
  final PixelPoint center;
  final double radiusPx;
  final double circularity; // 1.0 — идеальный круг

  const HoleCandidate({required this.center, required this.radiusPx, required this.circularity});
}

/// Блюр коробкой (box blur) — оценка "местного фона" в каждой точке.
/// Разделяемый (горизонтальный проход, потом вертикальный), поэтому
/// O(width*height) вместо O(width*height*radius^2).
GrayImage boxBlur(GrayImage src, int radius) {
  if (radius <= 0) return GrayImage(src.width, src.height, Uint8List.fromList(src.pixels));
  final w = src.width, h = src.height;
  final tmp = Float64List(w * h);
  final out = Uint8List(w * h);

  // Горизонтальный проход — скользящая сумма.
  for (var y = 0; y < h; y++) {
    var sum = 0.0;
    final rowOff = y * w;
    for (var x = -radius; x <= radius; x++) {
      sum += src.at(x.clamp(0, w - 1), y);
    }
    for (var x = 0; x < w; x++) {
      tmp[rowOff + x] = sum / (radius * 2 + 1);
      final addX = (x + radius + 1).clamp(0, w - 1);
      final subX = (x - radius).clamp(0, w - 1);
      sum += src.at(addX, y) - src.at(subX, y);
    }
  }

  // Вертикальный проход по результату горизонтального.
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var y = -radius; y <= radius; y++) {
      sum += tmp[y.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = (sum / (radius * 2 + 1)).round().clamp(0, 255);
      final addY = (y + radius + 1).clamp(0, h - 1);
      final subY = (y - radius).clamp(0, h - 1);
      sum += tmp[addY * w + x] - tmp[subY * w + x];
    }
  }
  return GrayImage(w, h, out);
}

/// Ищет НОВЫЕ пробоины в откалиброванной круглой области изображения.
///
/// Калибровка (центр + радиус в пикселях, соответствующий
/// `TargetFace.faceRadiusMm`) приходит СНАРУЖИ — пользователь выставляет
/// её сам, совместив круг с краем бланка на фото (раздел о фото в ТЗ:
/// авто-детект колец на произвольном фото при разном освещении и угле
/// ненадёжен без физической метки; ручная калибровка по кругу — тот же
/// принцип "по кольцам мишени", но не требует решать эту задачу вслепую).
///
/// Метод: локальный фон оценивается блюром (`boxBlur`), пробоина — это
/// пятно, заметно отличающееся от СВОЕГО ЖЕ размытого окружения (не от
/// глобальной яркости — иначе пробоина на белом поле и на чёрном яблоке
/// требовала бы разных порогов). Дальше — связные компоненты, фильтр по
/// ожидаemому диаметру (калибр мишени) и по круглости, и исключение
/// точек рядом с уже известными пробоинами.
List<HoleCandidate> findCandidateHoles({
  required GrayImage image,
  required PixelPoint center,
  required double radiusPx,
  required double caliberRadiusPx,
  List<PixelPoint> knownHolesPx = const [],
  double contrastThreshold = 28,
  double minCircularity = 0.85,
  // Второй радиус и поворот — калибровка эллипсом для фото, снятого под
  // углом (решение пользователя): по умолчанию совпадает с `radiusPx`,
  // то есть остаётся обычным кругом, ничего не меняя для всех
  // существующих вызовов. `angleRad` — поворот оси `radiusPx` от
  // горизонтали, по часовой стрелке (экранные координаты, Y вниз).
  double? radiusYPx,
  double angleRad = 0,
  // Печатные цифры габаритов (1..8) — детектор иногда принимает их за
  // пробоины (реальная находка пользователя: "путает с цифрами").
  // Позиции цифр на бланке ФИКСИРОВАНЫ относительно колец (тот же
  // принцип рисования, что у `TargetPainter._paintRingLabels` — середина
  // каждого габарита, четыре стороны света), поэтому их можно заранее
  // исключить из поиска, а не полагаться на то, что фильтр круглости
  // случайно отсеет ещё и цифру. Оба параметра нужны вместе — без них
  // исключение просто не применяется (ничего не меняется для вызовов,
  // где мишень ещё не выбрана).
  List<double>? ringRadiiMm,
  double? faceRadiusMm,
}) {
  final blurRadius = math.max(2, (caliberRadiusPx * 1.6).round());
  final blurred = boxBlur(image, blurRadius);

  final w = image.width, h = image.height;
  final visited = Uint8List(w * h);
  final candidates = <HoleCandidate>[];

  final ry = radiusYPx ?? radiusPx;
  final isCircle = angleRad == 0 && ry == radiusPx;
  final cosA = math.cos(angleRad), sinA = math.sin(angleRad);

  bool insideTarget(int x, int y) {
    final dx = x + 0.5 - center.x;
    final dy = y + 0.5 - center.y;
    if (isCircle) return dx * dx + dy * dy <= radiusPx * radiusPx;
    final xLocal = dx * cosA + dy * sinA;
    final yLocal = -dx * sinA + dy * cosA;
    return (xLocal * xLocal) / (radiusPx * radiusPx) + (yLocal * yLocal) / (ry * ry) <= 1;
  }

  // BFS-обход связных компонент по маске "заметно темнее/светлее своего
  // локального фона" — считаем на лету, не строя отдельную маску целиком,
  // чтобы не гонять по памяти лишний Uint8List на больших фото.
  final queueX = Int32List(w * h);
  final queueY = Int32List(w * h);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (visited[idx] != 0) continue;
      visited[idx] = 1;
      if (!insideTarget(x, y)) continue;
      final diff = (image.at(x, y) - blurred.at(x, y)).abs();
      if (diff < contrastThreshold) continue;

      // Начало новой компоненты — растим BFS тем же знаком отклонения
      // (все точки одной пробоины темнее ЛИБО все светлее локального
      // фона, не вперемешку — так пятно не "перетекает" в соседний
      // элемент разметки другого знака).
      final darker = image.at(x, y) < blurred.at(x, y);
      var head = 0;
      var tail = 0;
      queueX[tail] = x;
      queueY[tail] = y;
      tail++;
      var sumX = 0.0, sumY = 0.0, count = 0;
      var minX = x, maxX = x, minY = y, maxY = y;

      while (head < tail) {
        final cx = queueX[head];
        final cy = queueY[head];
        head++;
        sumX += cx + 0.5;
        sumY += cy + 0.5;
        count++;
        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;
        for (final d in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
          final nx = cx + d.$1, ny = cy + d.$2;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final nIdx = ny * w + nx;
          if (visited[nIdx] != 0) continue;
          if (!insideTarget(nx, ny)) continue;
          final nDiff = image.at(nx, ny) - blurred.at(nx, ny);
          final nDarker = nDiff < 0;
          if (nDarker != darker) continue;
          if (nDiff.abs() < contrastThreshold) continue;
          visited[nIdx] = 1;
          queueX[tail] = nx;
          queueY[tail] = ny;
          tail++;
        }
      }

      if (count < 3) continue; // одиночный пиксель шума
      final radius = math.sqrt(count / math.pi);
      final expectedMin = caliberRadiusPx * 0.5;
      final expectedMax = caliberRadiusPx * 1.8;
      if (radius < expectedMin || radius > expectedMax) continue;

      // Круглость — НЕ через площадь/радиус компоненты (радиус и так
      // выведен из площади, сравнение с самим собой всегда дало бы 1.0)
      // а через охватывающий прямоугольник: соотношение сторон и доля
      // заполнения. У круга заполнение ≈ π/4 ≈ 0.785, стороны почти
      // равны; у обрезка линии кольца — вытянутый прямоугольник и/или
      // низкое заполнение; у угла/квадрата — заполнение ближе к 1.0.
      final boxW = maxX - minX + 1;
      final boxH = maxY - minY + 1;
      final aspect = math.max(boxW, boxH) / math.min(boxW, boxH);
      final fillRatio = count / (boxW * boxH);
      final circularity = 1 - (fillRatio - math.pi / 4).abs() / (math.pi / 4);
      if (aspect > 1.6 || circularity < minCircularity) continue;

      final centroid = PixelPoint(sumX / count, sumY / count);
      candidates.add(HoleCandidate(center: centroid, radiusPx: radius, circularity: circularity.clamp(0, 1)));
    }
  }

  // Box blur размывает и в обратную сторону: вокруг пробоины остаётся
  // тонкое кольцо противоположного знака отклонения (то, что было
  // светлым, локально "просело" рядом с тёмным пятном, и наоборот) —
  // оно тоже проходит фильтры формы и размера и всплывает КОНЦЕНТРИЧНО
  // с настоящей пробоиной, как отдельный кандидат. Убираем дубликаты по
  // расстоянию, оставляя более круглый (обычно это и есть сама
  // пробоина, а не её ободок).
  candidates.sort((a, b) => b.circularity.compareTo(a.circularity));
  final deduped = <HoleCandidate>[];
  for (final c in candidates) {
    final overlaps = deduped.any((kept) {
      final dx = c.center.x - kept.center.x;
      final dy = c.center.y - kept.center.y;
      return dx * dx + dy * dy <= caliberRadiusPx * caliberRadiusPx;
    });
    if (!overlaps) deduped.add(c);
  }

  // Печатные цифры габаритов — фиксированное расположение относительно
  // колец (см. параметры `ringRadiiMm`/`faceRadiusMm` выше), считается
  // в ТОЙ ЖЕ системе координат (включая эллипс), что и `insideTarget`.
  final withoutLabels = (ringRadiiMm == null || faceRadiusMm == null || ringRadiiMm.length < 10 || faceRadiusMm <= 0)
      ? deduped
      : deduped.where((c) => !_nearRingLabel(
            c.center,
            center: center,
            radiusPx: radiusPx,
            radiusYPx: ry,
            angleRad: angleRad,
            ringRadiiMm: ringRadiiMm,
            faceRadiusMm: faceRadiusMm,
            tolerancePx: caliberRadiusPx * 1.3,
          )).toList();

  if (knownHolesPx.isEmpty) return withoutLabels;
  final matchTolerancePx = caliberRadiusPx * 1.2;
  return withoutLabels.where((c) {
    for (final known in knownHolesPx) {
      final dx = c.center.x - known.x;
      final dy = c.center.y - known.y;
      if (dx * dx + dy * dy <= matchTolerancePx * matchTolerancePx) return false;
    }
    return true;
  }).toList();
}

/// Позиция печатной цифры габарита N — середина кольца N, четыре
/// стороны света (тот же расчёт, что `TargetPainter._paintRingLabels`
/// использует для отрисовки в приложении, только в пиксельной системе
/// координат ФОТО, а не мм-системе экрана). `radiusYPx`/`angleRad` —
/// та же эллиптическая калибровка, что у `insideTarget` в
/// [findCandidateHoles], чтобы позиции цифр не "съезжали" на фото,
/// снятом под углом.
bool _nearRingLabel(
  PixelPoint p, {
  required PixelPoint center,
  required double radiusPx,
  required double radiusYPx,
  required double angleRad,
  required List<double> ringRadiiMm,
  required double faceRadiusMm,
  required double tolerancePx,
}) {
  const localDirs = [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)];
  final cosA = math.cos(angleRad), sinA = math.sin(angleRad);
  final tol2 = tolerancePx * tolerancePx;

  for (var ring = 1; ring <= 8; ring++) {
    final outerMm = ringRadiiMm[10 - ring];
    final innerMm = ringRadiiMm[9 - ring];
    final midMm = (outerMm + innerMm) / 2;
    final localX = midMm / faceRadiusMm * radiusPx;
    final localY = midMm / faceRadiusMm * radiusYPx;
    for (final d in localDirs) {
      final lx = d.$1 * localX, ly = d.$2 * localY;
      final labelX = center.x + (lx * cosA - ly * sinA);
      final labelY = center.y + (lx * sinA + ly * cosA);
      final dx = p.x - labelX, dy = p.y - labelY;
      if (dx * dx + dy * dy <= tol2) return true;
    }
  }
  return false;
}

/// Автоматическая калибровка круга мишени по фото: центр и радиус,
/// которые пользователь дальше может подправить руками.
///
/// Снимающий целится камерой в мишень, поэтому бланк — это заметно
/// отличающаяся от фона область вокруг ЦЕНТРА кадра. Фон оценивается по
/// уголкам кадра (туда бланк почти никогда не долетает), а сам бланк —
/// связная область вокруг центра, отличающаяся от этого фона сильнее
/// порога. Метод того же рода, что и `findCandidateHoles` — там пробоина
/// отличается от своего локального фона, здесь бланк отличается от фона
/// всего кадра.
///
/// `bullseyeToFaceRatio` — `TargetFace.faceRadiusMm / TargetFace.bullseyeRadiusMm`
/// для КОНКРЕТНОГО выбранного упражнения, если он известен вызывающему
/// коду (обычно известен — мишень выбирается раньше сканирования).
/// Разлив (см. ниже) чаще всего находит именно чёрное яблоко — оно
/// заметно контрастнее фона независимо от освещения, тогда как белое
/// поле бланка вокруг него от фона кадра может не отличаться вовсе.
/// Зная точное отношение «радиус всей мишени / радиус яблока» —
/// СВОЁ у каждой мишени, поэтому один и тот же множитель на все четыре
/// не годится — можно вычислить настоящий внешний радиус даже когда
/// фон кадра вокруг бланка не виден совсем (мишень занимает весь кадр).
///
/// Возвращает `null`, если довериться результату нельзя (кадр слишком
/// маленький, в центре сам фон, область почти не выросла или расползлась
/// до всех четырёх краёв кадра сразу) — вызывающий код в этом случае
/// оставляет прежнюю ручную калибровку по умолчанию.
({PixelPoint center, double radiusPx})? detectTargetCircle(GrayImage image, {double? bullseyeToFaceRatio}) {
  final w = image.width, h = image.height;
  if (w < 20 || h < 20) return null;

  final blurRadius = math.max(2, (math.min(w, h) * 0.01).round());
  final blurred = boxBlur(image, blurRadius);

  final patch = math.max(2, (math.min(w, h) * 0.04).round());
  double cornerAvg(int x0, int y0) {
    var sum = 0, count = 0;
    for (var y = y0; y < y0 + patch; y++) {
      for (var x = x0; x < x0 + patch; x++) {
        sum += blurred.at(x, y);
        count++;
      }
    }
    return sum / count;
  }

  final bg = (cornerAvg(0, 0) +
          cornerAvg(w - patch, 0) +
          cornerAvg(0, h - patch) +
          cornerAvg(w - patch, h - patch)) /
      4;

  const threshold = 24.0;
  bool differsFromBg(int x, int y) => (blurred.at(x, y) - bg).abs() >= threshold;

  final cx = w ~/ 2, cy = h ~/ 2;
  if (!differsFromBg(cx, cy)) return null;

  final visited = Uint8List(w * h);
  final queueX = Int32List(w * h);
  final queueY = Int32List(w * h);
  var head = 0, tail = 0;
  queueX[tail] = cx;
  queueY[tail] = cy;
  tail++;
  visited[cy * w + cx] = 1;
  var minX = cx, maxX = cx, minY = cy, maxY = cy, count = 0;

  while (head < tail) {
    final x = queueX[head];
    final y = queueY[head];
    head++;
    count++;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    for (final d in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nx = x + d.$1, ny = y + d.$2;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      final nIdx = ny * w + nx;
      if (visited[nIdx] != 0) continue;
      if (!differsFromBg(nx, ny)) continue;
      visited[nIdx] = 1;
      queueX[tail] = nx;
      queueY[tail] = ny;
      tail++;
    }
  }

  if (count < w * h * 0.03) return null;
  final touchesAllSides = minX == 0 && maxX == w - 1 && minY == 0 && maxY == h - 1;
  if (touchesAllSides) return null;

  final floodCenter = PixelPoint((minX + maxX) / 2, (minY + maxY) / 2);
  final floodRadius = math.max(maxX - minX, maxY - minY) / 2;

  // Разлив (BFS выше) останавливается на ПЕРВОЙ внутренней границе,
  // похожей на фон кадра — а у мишени такая граница часто есть задолго
  // до настоящего края бланка: например, чёрное яблоко в центре
  // заметно отличается от фона, но белое кольцо вокруг него — уже нет,
  // и разлив застревает на границе яблока, радиус выходит в разы
  // меньше настоящего. Дальше это ломает всё: калибр по такому радиусу
  // получается крошечным, размытие в findCandidateHoles — тоже, и
  // детектор пробоин начинает принимать буквально штрихи печатных
  // цифр за пробоины (реальная находка пользователя — мишень с
  // цифрами у колец).
  //
  // Лечится лучами: идём от края кадра К ЦЕНТРУ по многим направлениям
  // и берём точку, где лучу впервые попадается что-то, отличное от
  // фона, — так внешний край бланка находится независимо от связности
  // с центром, даже если между ним и найденным разливом есть кольца
  // цвета фона.
  const rays = 24;
  final rayRadii = <double>[];
  // Только ЛУЧИ, которые реально нашли границу (не уткнулись в
  // floodRadius по умолчанию), участвуют в уточнении ЦЕНТРА — иначе
  // "ненайденные" лучи (фон вокруг совпадает с бланком) тянули бы
  // центр к геометрии кадра, а не к настоящей мишени.
  final foundPoints = <PixelPoint>[];
  final foundAngles = <double>[];
  for (var i = 0; i < rays; i++) {
    final angle = 2 * math.pi * i / rays;
    final dx = math.cos(angle), dy = math.sin(angle);
    final edgeR = _rayDistanceToEdge(floodCenter.x, floodCenter.y, dx, dy, w, h);
    if (edgeR <= floodRadius) continue;
    double? found;
    for (var r = edgeR; r > floodRadius; r -= 2) {
      final x = (floodCenter.x + dx * r).round().clamp(0, w - 1);
      final y = (floodCenter.y + dy * r).round().clamp(0, h - 1);
      if (differsFromBg(x, y)) {
        found = r;
        break;
      }
    }
    if (found != null) {
      rayRadii.add(found);
      foundPoints.add(PixelPoint(floodCenter.x + dx * found, floodCenter.y + dy * found));
      foundAngles.add(angle);
    }
  }

  double rayRefinedRadius;
  if (rayRadii.isEmpty) {
    rayRefinedRadius = floodRadius;
  } else {
    rayRadii.sort();
    rayRefinedRadius = rayRadii[rayRadii.length ~/ 2];
  }

  // Уточнение ЦЕНТРА: для каждой пары лучей "туда-обратно" (углы,
  // отличающиеся примерно на 180°), у которых ОБА реально нашли
  // границу, настоящий центр мишени — середина отрезка между двумя
  // найденными точками (диаметр). Разлив от центра кадра может
  // ошибаться в центре мишени, если яблоко на фото несимметрично
  // (тень, блик, край кадра) — середины диаметров этой ошибки не
  // наследуют.
  final midpoints = <PixelPoint>[];
  for (var i = 0; i < foundAngles.length; i++) {
    for (var j = i + 1; j < foundAngles.length; j++) {
      final diff = (foundAngles[i] - foundAngles[j]).abs() % (2 * math.pi);
      final oppositeness = (diff - math.pi).abs();
      if (oppositeness < (2 * math.pi / rays) / 2) {
        midpoints.add(PixelPoint(
          (foundPoints[i].x + foundPoints[j].x) / 2,
          (foundPoints[i].y + foundPoints[j].y) / 2,
        ));
      }
    }
  }
  final refinedCenter = midpoints.isEmpty
      ? floodCenter
      : PixelPoint(
          midpoints.map((p) => p.x).reduce((a, b) => a + b) / midpoints.length,
          midpoints.map((p) => p.y).reduce((a, b) => a + b) / midpoints.length,
        );

  // Радиус и центр — выбор между двумя НЕЗАВИСИМЫМИ оценками:
  //
  // 1. По разливу-от-фона+лучам (rayRefinedRadius/refinedCenter выше).
  //    Ищет край "бумага отличается от фона кадра" — верно, когда
  //    бланк вырезан примерно по размеру мишени. Ошибается, если лист
  //    бумаги БОЛЬШЕ печатной мишени (поля, дописанные от руки заметки
  //    рядом с ней — реальная находка пользователя): разлив и лучи в
  //    этом случае цепляют край ВСЕГО ЛИСТА, не круга мишени, и дают
  //    результат заметно крупнее и часто не по центру.
  // 2. По тёмному яблоку в центре (ниже) — ищет не "отличается от
  //    фона", а буквально "тёмное пятно возле центра кадра" по
  //    абсолютной яркости, независимо от того, что на бумаге ещё
  //    напечатано или дописано. Яблоко есть на бланке всегда, и от
  //    оценки 1 не зависит вовсе.
  //
  // Если обе оценки согласуются — доверяем более точной (1). Если
  // сильно расходятся — доверяем геометрии (2): значит оценка 1
  // зацепила что-то лишнее, а не край мишени.
  ({PixelPoint center, double radiusPx})? bullseyeEstimate;
  if (bullseyeToFaceRatio != null) {
    final blob = _centralDarkBlobBbox(image);
    if (blob != null) {
      bullseyeEstimate = (
        center: PixelPoint((blob.minX + blob.maxX) / 2, (blob.minY + blob.maxY) / 2),
        radiusPx: math.max(blob.maxX - blob.minX, blob.maxY - blob.minY) / 2 * bullseyeToFaceRatio,
      );
    }
  }

  final foundRealEdge = rayRefinedRadius > floodRadius * 1.15;
  PixelPoint finalCenter;
  double finalRadius;
  if (bullseyeEstimate != null) {
    final ratio = rayRefinedRadius / bullseyeEstimate.radiusPx;
    final centerDx = refinedCenter.x - bullseyeEstimate.center.x;
    final centerDy = refinedCenter.y - bullseyeEstimate.center.y;
    final centerDist = math.sqrt(centerDx * centerDx + centerDy * centerDy);
    // Разлив от центра КАДРА (не яблока) начинается на кадре, а не на
    // мишени — если бумага крупнее и смещена, разлив/лучи находят её
    // центр, не центр яблока, и одно только совпадение радиусов это не
    // ловит: лист может случайно оказаться и нужного размера.
    final agrees = foundRealEdge && ratio > 0.7 && ratio < 1.4 && centerDist < bullseyeEstimate.radiusPx * 0.3;
    if (agrees) {
      finalCenter = refinedCenter;
      finalRadius = rayRefinedRadius;
    } else {
      finalCenter = bullseyeEstimate.center;
      finalRadius = bullseyeEstimate.radiusPx;
    }
  } else if (foundRealEdge) {
    finalCenter = refinedCenter;
    finalRadius = rayRefinedRadius;
  } else if (bullseyeToFaceRatio != null) {
    // Своё яблоко отдельным поиском не нашлось (редкость) — запасной
    // вариант через уже имеющийся разлив-от-фона, как было раньше.
    finalCenter = floodCenter;
    finalRadius = floodRadius * bullseyeToFaceRatio;
  } else {
    finalCenter = refinedCenter;
    finalRadius = rayRefinedRadius;
  }

  return (center: finalCenter, radiusPx: finalRadius);
}

/// Связная тёмная область вокруг ЦЕНТРА КАДРА по АБСОЛЮТНОЙ яркости
/// (порог — доля от средней яркости всего кадра), а не по отличию от
/// фона по краям — печатное яблоко мишени тёмное всегда, независимо от
/// того, что ещё есть на той же бумаге (поля, дописанные от руки
/// заметки, второй бланк рядом). Не зависит и не пересекается с
/// разливом-от-фона выше — источник для перепроверки его результата.
({int minX, int maxX, int minY, int maxY})? _centralDarkBlobBbox(GrayImage image) {
  final w = image.width, h = image.height;
  var sum = 0;
  for (final v in image.pixels) {
    sum += v;
  }
  final meanBrightness = sum / image.pixels.length;
  final darkThreshold = meanBrightness * 0.55;

  final cx = w ~/ 2, cy = h ~/ 2;
  if (image.at(cx, cy) >= darkThreshold) return null;

  final visited = Uint8List(w * h);
  final queueX = Int32List(w * h);
  final queueY = Int32List(w * h);
  var head = 0, tail = 0;
  queueX[tail] = cx;
  queueY[tail] = cy;
  tail++;
  visited[cy * w + cx] = 1;
  var minX = cx, maxX = cx, minY = cy, maxY = cy, count = 0;

  while (head < tail) {
    final x = queueX[head];
    final y = queueY[head];
    head++;
    count++;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    for (final d in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nx = x + d.$1, ny = y + d.$2;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      final nIdx = ny * w + nx;
      if (visited[nIdx] != 0) continue;
      if (image.at(nx, ny) >= darkThreshold) continue;
      visited[nIdx] = 1;
      queueX[tail] = nx;
      queueY[tail] = ny;
      tail++;
    }
  }

  if (count < w * h * 0.005) return null;
  return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// Расстояние от (cx,cy) до края прямоугольника w×h вдоль направления
/// (dx,dy) — сколько можно пройти по лучу, не выйдя за кадр.
double _rayDistanceToEdge(double cx, double cy, double dx, double dy, int w, int h) {
  var t = double.infinity;
  if (dx > 0) t = math.min(t, (w - 1 - cx) / dx);
  if (dx < 0) t = math.min(t, (0 - cx) / dx);
  if (dy > 0) t = math.min(t, (h - 1 - cy) / dy);
  if (dy < 0) t = math.min(t, (0 - cy) / dy);
  return t;
}

/// Переводит пиксельную точку в мм от центра мишени — та же система
/// координат, что и на экране мишени (Y вверх, а не вниз, как у пикселей
/// изображения).
PixelPoint pixelToMm(PixelPoint px, PixelPoint center, double radiusPx, double faceRadiusMm) {
  final scale = faceRadiusMm / radiusPx;
  return PixelPoint((px.x - center.x) * scale, -(px.y - center.y) * scale);
}

/// То же самое, но для калибровки ЭЛЛИПСОМ (фото под углом — пункты 1 и
/// 3 списка правок): `radiusXPx`/`radiusYPx` — полуоси эллипса на фото,
/// `angleRad` — поворот оси `radiusXPx` от горизонтали по часовой
/// стрелке. Идея та же, что у поворота осей в геометрии: точку сначала
/// переводят в систему координат самого эллипса (отменяют поворот), а
/// потом масштабируют по каждой оси СВОИМ коэффициентом — так
/// сплюснутый под углом камеры круг разворачивается обратно в
/// настоящую окружность мишени. При `angleRad == 0` и
/// `radiusXPx == radiusYPx` даёт точно то же число, что и [pixelToMm].
PixelPoint pixelToMmEllipse(
  PixelPoint px,
  PixelPoint center,
  double radiusXPx,
  double radiusYPx,
  double angleRad,
  double faceRadiusMm,
) {
  final dx = px.x - center.x;
  final dy = px.y - center.y;
  final cosA = math.cos(angleRad), sinA = math.sin(angleRad);
  final xLocal = dx * cosA + dy * sinA;
  final yLocal = -dx * sinA + dy * cosA;
  final xMm = xLocal / radiusXPx * faceRadiusMm;
  final yMm = yLocal / radiusYPx * faceRadiusMm;
  return PixelPoint(xMm, -yMm);
}

/// Обратное преобразование к [pixelToMmEllipse] — из мм от центра
/// мишени обратно в пиксели ИСХОДНОГО фото. Нужно, чтобы уже известные
/// пробоины (в мм) можно было исключить из повторного поиска на новом
/// фото той же тренировки.
PixelPoint mmToPixelEllipse(
  PixelPoint mm,
  PixelPoint center,
  double radiusXPx,
  double radiusYPx,
  double angleRad,
  double faceRadiusMm,
) {
  final xLocal = mm.x / faceRadiusMm * radiusXPx;
  final yLocal = -mm.y / faceRadiusMm * radiusYPx;
  final cosA = math.cos(angleRad), sinA = math.sin(angleRad);
  final dx = xLocal * cosA - yLocal * sinA;
  final dy = xLocal * sinA + yLocal * cosA;
  return PixelPoint(center.x + dx, center.y + dy);
}

/// Уточняет РАДИУС калибровки (масштаб мм↔пиксели) по печатным кольцам
/// мишени — а не по контрасту "мишень/фон", как `detectTargetCircle`.
///
/// У каждой мишени напечатано ровно 10 колец на ТОЧНО известных
/// расстояниях от центра (`TargetFace.ringRadiiMm`) — это куда более
/// надёжный ориентир, чем форма пятна или край листа бумаги (который
/// может быть больше самой мишени — см. `detectTargetCircle`). Метод:
/// перебором масштаба ищем такой, при котором ожидаемые границы всех
/// десяти колец сильнее всего совпадают с реальными перепадами яркости
/// на фото — окружность на предсказанном радиусе кольца либо застаёт
/// границу (сильный перепад между чуть меньшим и чуть большим
/// радиусом), либо нет (случайный масштаб чаще попадает в ровную,
/// однотонную часть кольца). Верный масштаб выигрывает за счёт
/// накопления по всем 10 кольцам и многим углам — шум одной точки на
/// общий счёт почти не влияет.
///
/// Центр НЕ уточняется — только масштаб; `initialRadiusPx` (обычно —
/// результат `detectTargetCircle`) должен быть в разумных пределах от
/// истинного (поиск идёт в диапазоне 0.6×..1.6× от него), иначе перебор
/// рискует сойтись на случайном совпадении.
double refineRadiusByRings({
  required GrayImage image,
  required PixelPoint center,
  required double initialRadiusPx,
  required List<double> ringRadiiMm,
  required double faceRadiusMm,
}) {
  if (initialRadiusPx <= 0 || ringRadiiMm.isEmpty || faceRadiusMm <= 0) return initialRadiusPx;
  final w = image.width, h = image.height;
  const angleSamples = 24;
  const scaleSteps = 80;
  const scaleRangeMin = 0.6;
  const scaleRangeMax = 1.6;
  final maxSamplingRadius = math.min(w, h) * 0.6;

  double sampleAt(double x, double y) {
    final xi = x.round().clamp(0, w - 1);
    final yi = y.round().clamp(0, h - 1);
    return image.at(xi, yi).toDouble();
  }

  // Разброс (максимум минус минимум) в окне В НЕСКОЛЬКО ПИКСЕЛЕЙ вокруг
  // r, а не просто разница двух точек на фиксированном расстоянии от
  // r: печатная линия кольца тонкая (пара пикселей), и при росте r
  // фиксированная-в-долях-от-r дельта рано или поздно перестаёт на неё
  // попадать вообще, давая нулевой сигнал даже на верном масштабе.
  // Разброс по окну ловит линию, где бы она внутри окна ни оказалась.
  const window = [-3, -2, -1, 0, 1, 2, 3];

  double scoreForScale(double scalePx) {
    var score = 0.0;
    for (final ringMm in ringRadiiMm) {
      final r = ringMm / faceRadiusMm * scalePx;
      if (r < 4 || r > maxSamplingRadius) continue;
      for (var i = 0; i < angleSamples; i++) {
        final angle = 2 * math.pi * i / angleSamples;
        final dx = math.cos(angle), dy = math.sin(angle);
        var lo = 255.0, hi = 0.0;
        for (final k in window) {
          final v = sampleAt(center.x + dx * (r + k), center.y + dy * (r + k));
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        score += hi - lo;
      }
    }
    return score;
  }

  double search(double from, double to, int steps) {
    var bestScale = initialRadiusPx;
    var bestScore = -1.0;
    for (var i = 0; i <= steps; i++) {
      final scale = from + (to - from) * i / steps;
      final score = scoreForScale(scale);
      if (score > bestScore) {
        bestScore = score;
        bestScale = scale;
      }
    }
    return bestScale;
  }

  // Грубый проход по широкому диапазону, затем точный — в узком окне
  // вокруг найденного — той же ценой, что и один грубый проход вдвое
  // мельче, но без риска промахнуться мимо истинного пика на широком
  // диапазоне из-за крупного шага.
  final coarse = search(initialRadiusPx * scaleRangeMin, initialRadiusPx * scaleRangeMax, scaleSteps);
  final step = initialRadiusPx * (scaleRangeMax - scaleRangeMin) / scaleSteps;
  return search(coarse - step, coarse + step, scaleSteps);
}
