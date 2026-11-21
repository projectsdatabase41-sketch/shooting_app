import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Четыре графика «обзора статистики» (перенос промпта AnalyticsBento).
///
/// Источник — React-компонент из `Документы\Prompts` (см.
/// `docs/ui-prompts-map.md`). Здесь только отрисовка: как и в
/// `analytics_painters.dart`, painter'ы НЕ читают `Theme.of(context)` сами —
/// цвета приходят параметрами. Так один и тот же график рисуется в светлой
/// и тёмной теме и в тестах, без поднятого дерева виджетов.
///
/// Отличия от референса, принятые осознанно:
/// - «волны» в оригинале уходят вверх и вниз от средней оси (две серии:
///   desktop/mobile). У очков стрельбы такой симметрии нет — вторая серия
///   просто рисовалась бы вниз и читалась как отрицательный результат.
///   Поэтому обе серии идут от одной нижней оси, вторая — бледнее;
/// - интерактивных tooltip'ов нет: на телефоне наведение отсутствует, а
///   повторять его для мыши в вебе — отдельная задача;
/// - бесконечного «дыхания» нет: на CanvasKit это постоянная перерисовка.

/// Общий помощник: сглаженный путь по точкам (Catmull-Rom → кубические
/// Безье, коэффициент 0.18 — как в Peak Chart). Без сглаживания ломаная по
/// 10–30 точкам выглядит как осциллограмма, а не как результат стрельбы.
Path smoothThrough(List<Offset> pts, {double k = 0.18}) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = i == 0 ? pts[0] : pts[i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = i + 2 < pts.length ? pts[i + 2] : pts[pts.length - 1];
    final c1 = Offset(p1.dx + (p2.dx - p0.dx) * k, p1.dy + (p2.dy - p0.dy) * k);
    final c2 = Offset(p2.dx - (p3.dx - p1.dx) * k, p2.dy - (p3.dy - p1.dy) * k);
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// Линия динамики с заливкой под ней и точкой на последнем значении.
class BentoTrendPainter extends CustomPainter {
  final List<double> values;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;

  const BentoTrendPainter({
    required this.values,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 1 || size.height <= 1) return;

    // Поле под линию: заливка доходит до низа, а последняя точка должна
    // читаться — поэтому сверху и снизу оставляем по 6% на точку и тень.
    const padTop = 10.0;
    const padBottom = 8.0;
    final h = size.height - padTop - padBottom;
    final plotW = size.width - 4;

    var lo = values.reduce(math.min);
    var hi = values.reduce(math.max);
    if (hi - lo < 0.001) {
      // Плоский ряд (все тренировки одинаковые) не должен вырождаться в
      // линию по нижнему краю: раздвигаем шкалу на полбалла.
      lo -= 0.5;
      hi += 0.5;
    }
    final span = hi - lo;

    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          values.length == 1 ? size.width / 2 : 2 + i / (values.length - 1) * plotW,
          padTop + (1 - (values[i] - lo) / span) * h,
        ),
    ];

    // Сетка: четыре горизонтали, самая нижняя — база заливки.
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = padTop + h * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (pts.length == 1) {
      canvas.drawCircle(pts.first, 3, Paint()..color = lineColor);
      return;
    }

    final line = smoothThrough(pts);
    final area = Path.from(line)
      ..lineTo(pts.last.dx, size.height - padBottom)
      ..lineTo(pts.first.dx, size.height - padBottom)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, padTop),
          Offset(0, size.height - padBottom),
          [fillColor, fillColor.withValues(alpha: 0)],
        ),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(pts.last, 3.2, Paint()..color = lineColor);
  }

  @override
  bool shouldRepaint(BentoTrendPainter old) =>
      old.lineColor != lineColor ||
      old.fillColor != fillColor ||
      old.gridColor != gridColor ||
      !_sameList(old.values, values);

  static bool _sameList(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Две серии выстрелов (текущая и предыдущая) сглаженными линиями от одной
/// нижней оси.
class BentoWavesPainter extends CustomPainter {
  /// Первая серия — текущая (яркая), вторая — прошлая (бледная).
  final List<List<double>> series;
  final List<Color> colors;
  final Color gridColor;
  final List<String> labels;
  final TextStyle labelStyle;

  const BentoWavesPainter({
    required this.series,
    required this.colors,
    required this.gridColor,
    required this.labels,
    required this.labelStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rows = series.where((s) => s.isNotEmpty).toList();
    if (rows.isEmpty || size.width <= 1 || size.height <= 1) return;

    const padBottom = 18.0;
    const padTop = 8.0;
    final h = size.height - padTop - padBottom;

    var hi = 0.0;
    for (final row in rows) {
      for (final v in row) {
        if (v > hi) hi = v;
      }
    }
    if (hi <= 0) hi = 1;

    // Общий максимум по обеим сериям: иначе текущая серия, стрелянная
    // лучше, всё равно занимала бы всю высоту, и сравнение врало бы.
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - padBottom), Offset(size.width, size.height - padBottom), grid);

    for (var s = 0; s < rows.length; s++) {
      final row = rows[s];
      final color = colors[s % colors.length];
      final pts = <Offset>[
        for (var i = 0; i < row.length; i++)
          Offset(
            row.length == 1 ? size.width / 2 : i / (row.length - 1) * (size.width - 2),
            padTop + (1 - row[i] / hi) * h,
          ),
      ];
      if (pts.length < 2) continue;
      final path = smoothThrough(pts);
      if (s == 0) {
        final area = Path.from(path)
          ..lineTo(pts.last.dx, size.height - padBottom)
          ..lineTo(pts.first.dx, size.height - padBottom)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, padTop),
              Offset(0, size.height - padBottom),
              [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
            ),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s == 0 ? 2.4 : 1.4
          ..strokeCap = StrokeCap.round,
      );
      if (s == 0) {
        for (final p in pts) {
          canvas.drawCircle(p, 1.8, Paint()..color = color);
        }
      }
    }

    // Подписи по X — номера выстрелов в серии. Показываем не больше шести:
    // десяток подписей в узкую карточку не влезает.
    if (labels.isEmpty) return;
    final step = (labels.length / 6).ceil().clamp(1, labels.length);
    for (var i = 0; i < labels.length; i += step) {
      final tp = TextPainter(text: TextSpan(text: labels[i], style: labelStyle), textDirection: TextDirection.ltr)..layout();
      final x = labels.length == 1 ? size.width / 2 : i / (labels.length - 1) * (size.width - 2);
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - padBottom + 4));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(BentoWavesPainter old) => true;
}

/// Один прямоугольник treemap: подпись (габарит), значение, цвет.
class BentoSlice {
  final String label;
  final int value;
  final Color color;

  const BentoSlice({required this.label, required this.value, required this.color});
}

/// Treemap «сколько выстрелов в каком габарите».
///
/// Площадь плитки — доля выстрелов, цвет — тем насыщеннее, чем выше
/// габарит. Это перенос третьей карточки AnalyticsBento: там площадь тоже
/// считалась через squarify, а не «руками расставленными» квадратами.
class BentoTreemapPainter extends CustomPainter {
  final List<BentoSlice> items;
  final TextStyle labelStyle;
  final TextStyle valueStyle;
  final Color emptyColor;

  const BentoTreemapPainter({
    required this.items,
    required this.labelStyle,
    required this.valueStyle,
    required this.emptyColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 1 || size.height <= 1) return;
    final visible = items.where((e) => e.value > 0).toList();
    if (visible.isEmpty) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
        Paint()..color = emptyColor,
      );
      return;
    }

    final rects = squarify(
      [for (final e in visible) e.value.toDouble()],
      Offset.zero & size,
    );

    for (var i = 0; i < rects.length && i < visible.length; i++) {
      final r = rects[i].deflate(2);
      if (r.width <= 2 || r.height <= 2) continue;
      final item = visible[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(8)),
        Paint()..color = item.color,
      );

      // Текст рисуем, только если он туда влезает: обрезанное «10» на
      // плитке шириной 14 px читается как случайные чёрточки.
      if (r.width < 34 || r.height < 26) continue;
      final label = item.label;
      final value = '${item.value}';
      final big = r.height >= 54 && r.width >= 56;
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: label, style: big ? valueStyle : labelStyle),
          if (big) TextSpan(text: '\n$value', style: labelStyle),
        ]),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: big ? 3 : 1,
        ellipsis: '…',
      )..layout(maxWidth: r.width - 8);
      tp.paint(canvas, Offset(r.left + (r.width - tp.width) / 2, r.top + (r.height - tp.height) / 2));
      tp.dispose();
    }
  }

  /// Классический squarify (Bruls, Huizing, van Wijk): ряды кладутся вдоль
  /// короткой стороны, пока это улучшает соотношение сторон.
  static List<Rect> squarify(List<double> values, Rect bounds) {
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0 || bounds.width <= 0 || bounds.height <= 0) return const [];
    final scale = bounds.width * bounds.height / total;
    final areas = [for (final v in values) v * scale];

    final out = <Rect>[];
    var x = bounds.left;
    var y = bounds.top;
    var w = bounds.width;
    var h = bounds.height;
    var i = 0;

    while (i < areas.length) {
      final side = math.min(w, h);
      final row = <double>[];
      var rowArea = 0.0;
      while (i < areas.length) {
        final next = rowArea + areas[i];
        if (row.isNotEmpty && _worst(row, rowArea, side) < _worst([...row, areas[i]], next, side)) break;
        row.add(areas[i]);
        rowArea = next;
        i++;
      }
      if (row.isEmpty) break;
      if (w >= h) {
        final d = rowArea / h;
        var yy = y;
        for (final a in row) {
          final rh = d == 0 ? 0.0 : a / d;
          out.add(Rect.fromLTWH(x, yy, d, rh));
          yy += rh;
        }
        x += d;
        w -= d;
      } else {
        final d = rowArea / w;
        var xx = x;
        for (final a in row) {
          final rw = d == 0 ? 0.0 : a / d;
          out.add(Rect.fromLTWH(xx, y, rw, d));
          xx += rw;
        }
        y += d;
        h -= d;
      }
    }
    return out;
  }

  /// Худшее соотношение сторон в ряду (Bruls/Huizing/van Wijk):
  /// `max(max·side²/area², area²/(min·side²))`, где `area` — сумма ряда,
  /// `side` — короткая сторона оставшегося прямоугольника.
  static double _worst(List<double> row, double area, double side) {
    if (row.isEmpty || area <= 0 || side <= 0) return double.infinity;
    var mn = row.first;
    var mx = row.first;
    for (final a in row) {
      if (a < mn) mn = a;
      if (a > mx) mx = a;
    }
    if (mn <= 0) return double.infinity;
    final s2 = side * side;
    final a2 = area * area;
    return math.max(mx * s2 / a2, a2 / (mn * s2));
  }

  @override
  bool shouldRepaint(BentoTreemapPainter old) =>
      old.items.length != items.length ||
      old.labelStyle != labelStyle ||
      old.emptyColor != emptyColor ||
      [for (var i = 0; i < items.length; i++) items[i].value != old.items[i].value || items[i].color != old.items[i].color]
          .any((changed) => changed);
}

/// Радар «средний выстрел по месяцам».
///
/// Контур сглаживается рядом Фурье (K = min(5, N/2)) — как в референсе:
/// без него двенадцать точек дают зубчатую звезду. Нормировка в 0.42…1
/// не даёт лучам схлопнуться в центр, когда месяцы близки по результату.
class BentoRadarPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final TextStyle labelStyle;

  const BentoRadarPainter({
    required this.values,
    required this.labels,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.labelStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n < 3 || size.width <= 1 || size.height <= 1) return;

    final side = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final r = side / 2 - 22;

    final grid = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final k in [0.33, 0.66, 1.0]) {
      canvas.drawCircle(c, r * k, grid);
    }
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i / n * 2 * math.pi;
      canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * r, grid);
    }

    var lo = values.reduce(math.min);
    var hi = values.reduce(math.max);
    if (hi - lo < 0.001) {
      lo -= 0.5;
      hi += 0.5;
    }
    final norm = [
      for (final v in values) 0.42 + ((v - lo) / (hi - lo)) * 0.58,
    ];

    final coeffs = _fourier(norm);
    double f(double theta) {
      var sum = coeffs[0].$1;
      for (var k = 1; k < coeffs.length; k++) {
        sum += coeffs[k].$1 * math.cos(k * theta) + coeffs[k].$2 * math.sin(k * theta);
      }
      return sum;
    }

    const steps = 180;
    final path = Path();
    for (var s = 0; s <= steps; s++) {
      final theta = s / steps * 2 * math.pi;
      final rr = r * 0.2 + math.max(0.05, f(theta)).clamp(0.0, 1.2).toDouble() * r * 0.8;
      final a = -math.pi / 2 + theta;
      final p = c + Offset(math.cos(a), math.sin(a)) * rr;
      if (s == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    canvas.drawPath(path, Paint()..color = fillColor);
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    // Подписи месяцев по кругу. Если места мало, подпись ставим ближе к
    // центру: на карточке 280 px слова «январь» и «февраль» иначе
    // перекрывают друг друга.
    final compact = side < 300;
    for (var i = 0; i < n && i < labels.length; i++) {
      final a = -math.pi / 2 + i / n * 2 * math.pi;
      final rr = r + (compact ? 10 : 14);
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      var p = c + Offset(math.cos(a), math.sin(a)) * rr;
      p = Offset(p.dx - tp.width / 2, p.dy - tp.height / 2);
      tp.paint(canvas, p);
      tp.dispose();
    }
  }

  /// Коэффициенты ряда Фурье по равномерным отсчётам: [(a0), (a1,b1), …].
  static List<(double, double)> _fourier(List<double> x) {
    final n = x.length;
    final kMax = math.min(5, n ~/ 2);
    final out = <(double, double)>[];
    for (var k = 0; k <= kMax; k++) {
      var a = 0.0;
      var b = 0.0;
      for (var i = 0; i < n; i++) {
        final t = i / n * 2 * math.pi;
        final w = k == 0 ? 1 / n : 2 / n;
        a += x[i] * math.cos(k * t) * w;
        b += x[i] * math.sin(k * t) * w;
      }
      out.add((a, b));
    }
    return out;
  }

  @override
  bool shouldRepaint(BentoRadarPainter old) => true;
}

