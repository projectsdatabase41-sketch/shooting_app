import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../logic/shot_analytics.dart';
import '../models/shot.dart';
import '../models/target_face.dart';

/// Три графика разбора стрельбы. Все — свои `CustomPainter` без внешних
/// библиотек (раздел 5 ТЗ), в одном файле, потому что они всегда
/// используются вместе, одним блоком (`AnalyticsPanel`).
///
/// Общее правило по цветам: painter'ы НЕ лезут в `Theme.of(context)`
/// сами — цвета передаются параметрами. Так их можно рисовать и в
/// светлой, и в тёмной теме, и в тестах, не поднимая дерево виджетов.

/// Гистограмма "сколько выстрелов в каком габарите".
///
/// Горизонтальные полосы, а не вертикальные: подписи габаритов (10, 9,
/// 8...) и количество читаются в строку, а при вертикальных столбцах на
/// узком экране подписи пришлось бы поворачивать.
class RingDistributionPainter extends CustomPainter {
  /// Строки гистограммы сверху вниз: подпись и количество.
  ///
  /// Раньше painter принимал `Map<int,int>` и сам знал, что подпись —
  /// это габарит. Теперь строки готовит панель: та же гистограмма
  /// рисует и габариты (10, 9, 8…), и разбивку десятки по десятым
  /// (10.9, 10.8…), когда все выстрелы легли в десятку.
  final List<({String label, int count})> rows;
  final Color barColor;
  final Color axisColor;

  /// Ширина колонки подписей. «10.9» шире, чем «10», и на общей ширине
  /// столбики бы разъезжались.
  final double labelWidth;

  RingDistributionPainter({
    required this.rows,
    required this.barColor,
    required this.axisColor,
    this.labelWidth = 22,
  });

  static const double _countWidth = 30;
  static const double _rowGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;

    final maxCount = rows.fold<int>(0, (a, r) => a > r.count ? a : r.count);
    final rowHeight = (size.height - _rowGap * (rows.length - 1)) / rows.length;
    if (rowHeight <= 0) return;

    final barLeft = labelWidth + 6;
    final barMaxWidth = size.width - barLeft - _countWidth;
    if (barMaxWidth <= 0) return;

    final trackPaint = Paint()..color = axisColor.withValues(alpha: 0.12);
    final barPaint = Paint()..color = barColor;

    for (var i = 0; i < rows.length; i++) {
      final count = rows[i].count;
      final top = i * (rowHeight + _rowGap);
      final barHeight = math.min(rowHeight, 14.0);
      final barTop = top + (rowHeight - barHeight) / 2;

      _drawText(canvas, rows[i].label, Offset(labelWidth, top + rowHeight / 2), axisColor, 11,
          align: TextAlign.right, bold: true);

      final trackRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(barLeft, barTop, barMaxWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(trackRect, trackPaint);

      if (count > 0 && maxCount > 0) {
        // Минимальная видимая ширина: одна единица из большого набора
        // иначе вырождается в невидимую полоску нулевой ширины.
        final w = math.max(barMaxWidth * count / maxCount, 3.0);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(barLeft, barTop, w, barHeight),
            const Radius.circular(4),
          ),
          barPaint,
        );
      }

      _drawText(canvas, '$count', Offset(size.width, top + rowHeight / 2), axisColor, 11,
          align: TextAlign.right);
    }
  }

  @override
  bool shouldRepaint(covariant RingDistributionPainter old) {
    if (old.barColor != barColor ||
        old.axisColor != axisColor ||
        old.labelWidth != labelWidth ||
        old.rows.length != rows.length) {
      return true;
    }
    for (var i = 0; i < rows.length; i++) {
      if (old.rows[i].label != rows[i].label || old.rows[i].count != rows[i].count) return true;
    }
    return false;
  }
}

/// Карта попаданий: пробоины, СТП и круг кучности.
///
/// Масштаб подбирается по самой дальней пробоине, а не по бланку мишени:
/// на срезе одной хорошей серии все выстрелы лежат в пределах десятки, и
/// на полном бланке группа выродилась бы в точку. Кольца мишени
/// рисуются те, что попадают в выбранный масштаб.
class GroupScatterPainter extends CustomPainter {
  final List<Shot> shots;
  final TargetFace face;
  final Offset meanPointMm;

  /// Радиус СТП (Mean Radius) — среднее расстояние пробоин до центра
  /// группы. Строгая метрика кучности, в отличие от «среднего разброса».
  final double meanRadiusMm;

  /// Окружность максимального рассеивания: центр и радиус в мм.
  /// `null` — выстрелов слишком мало или слишком много для расчёта.
  final Offset? spreadCenterMm;
  final double? spreadRadiusMm;

  /// Радиусы вокруг СТП, внутрь которых попадает половина и девять
  /// десятых выстрелов. `null` — выборка мала.
  final double? cep50Mm;
  final double? cep90Mm;

  /// Рисовать ли номер выстрела внутри пробоины. На срезе в тысячу
  /// выстрелов цифры сливаются в кашу, поэтому решает вызывающий.
  final bool showNumbers;

  final Color shotColor;
  final Color meanColor;
  final Color ringColor;

  GroupScatterPainter({
    required this.shots,
    required this.face,
    required this.meanPointMm,
    required this.meanRadiusMm,
    required this.shotColor,
    required this.meanColor,
    required this.ringColor,
    this.spreadCenterMm,
    this.spreadRadiusMm,
    this.cep50Mm,
    this.cep90Mm,
    this.showNumbers = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxPx = math.min(size.width, size.height) / 2 - 6;
    if (maxPx <= 0 || shots.isEmpty) return;

    // Радиус охвата: самая дальняя пробоина плюс её собственный радиус,
    // минимум — чтобы не делить на ноль и не растягивать одну пробоину
    // на весь холст.
    var spanMm = face.caliberRadiusMm * 3;
    for (final s in shots) {
      final r = s.radiusMm + face.caliberRadiusMm;
      if (r > spanMm) spanMm = r;
    }
    // Окружность рассеивания строится вокруг центра ГРУППЫ, а не центра
    // мишени, и при сильно смещённой группе вылезала бы за холст.
    final sc = spreadCenterMm;
    final sr = spreadRadiusMm;
    if (sc != null && sr != null) {
      final reach = sc.distance + sr;
      if (reach > spanMm) spanMm = reach;
    }
    final mmToPx = maxPx / spanMm;

    final ringPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final rMm in face.ringRadiiMm) {
      if (rMm > spanMm) break;
      canvas.drawCircle(center, rMm * mmToPx, ringPaint);
    }

    // Перекрестие центра мишени.
    final crossPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx - maxPx, center.dy), Offset(center.dx + maxPx, center.dy), crossPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxPx), Offset(center.dx, center.dy + maxPx), crossPaint);

    final meanPos = center + Offset(meanPointMm.dx, -meanPointMm.dy) * mmToPx;

    // Окружность максимального рассеивания — самая внешняя, поэтому
    // рисуется первой и пунктиром: это габарит группы, а не метрика
    // кучности, и спорить с кругами CEP за внимание ей незачем.
    if (sc != null && sr != null && sr > 0) {
      _dashedCircle(
        canvas,
        center + Offset(sc.dx, -sc.dy) * mmToPx,
        sr * mmToPx,
        Paint()
          ..color = ringColor.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // Круги CEP: внутри 90% и 50% выстрелов. Заливка слабая, нарастающая
    // к центру — так «ядро» группы видно сразу, без чтения цифр.
    void cep(double? r, double alpha) {
      if (r == null || r <= 0) return;
      canvas.drawCircle(
        meanPos,
        r * mmToPx,
        Paint()..color = meanColor.withValues(alpha: alpha),
      );
    }

    cep(cep90Mm, 0.08);
    cep(cep50Mm, 0.12);

    if (cep50Mm != null && cep50Mm! > 0) {
      canvas.drawCircle(
        meanPos,
        cep50Mm! * mmToPx,
        Paint()
          ..color = meanColor.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // Круг радиуса СТП — основная метрика кучности, сплошной линией.
    if (meanRadiusMm > 0) {
      canvas.drawCircle(
        meanPos,
        meanRadiusMm * mmToPx,
        Paint()
          ..color = meanColor.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final shotRadiusPx = math.max(face.caliberRadiusMm * mmToPx, 1.5);
    final shotPaint = Paint()..color = shotColor.withValues(alpha: 0.65);
    final numbers = showNumbers && shotRadiusPx >= 6;
    for (final s in shots) {
      // Экранная Y инвертирована относительно мм-координат — та же
      // конвенция, что и в TargetPainter.
      final pos = center + Offset(s.xMm, -s.yMm) * mmToPx;
      canvas.drawCircle(pos, shotRadiusPx, shotPaint);
      if (numbers) {
        _drawText(
          canvas,
          '${s.shotNumber}',
          pos,
          ringColor,
          math.min(shotRadiusPx * 0.95, 11),
          align: TextAlign.center,
          centerY: true,
          bold: true,
        );
      }
    }

    // Линия от центра мишени к СТП — куда именно ушла группа. Без неё
    // «смещение 0.1 мм» ничего не говорит: неясно, в какую сторону.
    if (meanPointMm.distance > 1e-6) {
      canvas.drawLine(
        center,
        meanPos,
        Paint()
          ..color = meanColor.withValues(alpha: 0.55)
          ..strokeWidth = 1.2,
      );
    }

    // Сама СТП — крестом, а не точкой: точка терялась бы среди пробоин.
    final meanPaint = Paint()
      ..color = meanColor
      ..strokeWidth = 2;
    const arm = 7.0;
    canvas.drawLine(meanPos - const Offset(arm, 0), meanPos + const Offset(arm, 0), meanPaint);
    canvas.drawLine(meanPos - const Offset(0, arm), meanPos + const Offset(0, arm), meanPaint);
  }

  /// Пунктирная окружность. В Flutter из коробки пунктира нет, поэтому
  /// рисуем дугами: длина штриха задана в пикселях, чтобы на большом и
  /// маленьком круге пунктир выглядел одинаково.
  static void _dashedCircle(Canvas canvas, Offset c, double r, Paint paint) {
    if (r <= 0) return;
    const dashPx = 6.0;
    const gapPx = 4.0;
    final circumference = 2 * math.pi * r;
    final steps = math.max((circumference / (dashPx + gapPx)).floor(), 8);
    final sweep = 2 * math.pi / steps;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var i = 0; i < steps; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant GroupScatterPainter old) {
    return old.shots != shots ||
        old.face != face ||
        old.meanPointMm != meanPointMm ||
        old.meanRadiusMm != meanRadiusMm ||
        old.spreadCenterMm != spreadCenterMm ||
        old.spreadRadiusMm != spreadRadiusMm ||
        old.cep50Mm != cep50Mm ||
        old.cep90Mm != cep90Mm ||
        old.showNumbers != showNumbers ||
        old.shotColor != shotColor ||
        old.meanColor != meanColor ||
        old.ringColor != ringColor;
  }
}

/// Столбики "средний результат по сериям".
class SeriesBarsPainter extends CustomPainter {
  final List<SeriesStat> series;
  final double maxY;
  final Color barColor;
  final Color axisColor;

  SeriesBarsPainter({
    required this.series,
    required this.barColor,
    required this.axisColor,
    this.maxY = 10.9,
  });

  static const double _leftMargin = 26;
  static const double _bottomMargin = 18;

  @override
  void paint(Canvas canvas, Size size) {
    const plotLeft = _leftMargin;
    final plotBottom = size.height - _bottomMargin;
    final plotWidth = size.width - plotLeft;
    final plotHeight = plotBottom;
    if (plotWidth <= 0 || plotHeight <= 0 || maxY <= 0) return;

    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var v = 0.0; v <= maxY + 1e-9; v += maxY / 4) {
      final py = plotBottom - (v / maxY) * plotHeight;
      canvas.drawLine(Offset(plotLeft, py), Offset(size.width, py), gridPaint);
      _drawText(canvas, v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1),
          Offset(plotLeft - 5, py), axisColor, 9,
          align: TextAlign.right, centerY: true);
    }

    if (series.isEmpty) {
      _drawText(canvas, 'Нет серий', Offset(size.width / 2, plotHeight / 2), axisColor, 12,
          align: TextAlign.center, centerY: true);
      return;
    }

    final slot = plotWidth / series.length;
    final barWidth = math.min(slot * 0.6, 34.0);
    final barPaint = Paint()..color = barColor;

    for (var i = 0; i < series.length; i++) {
      final s = series[i];
      final cx = plotLeft + slot * (i + 0.5);
      final h = (s.average / maxY).clamp(0.0, 1.0) * plotHeight;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - barWidth / 2, plotBottom - h, barWidth, h),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        barPaint,
      );
      _drawText(canvas, '${s.seriesNo}', Offset(cx, plotBottom + 3), axisColor, 9,
          align: TextAlign.center);
    }
  }

  @override
  bool shouldRepaint(covariant SeriesBarsPainter old) {
    return old.series != series ||
        old.maxY != maxY ||
        old.barColor != barColor ||
        old.axisColor != axisColor;
  }
}

/// Общий помощник отрисовки подписи. `centerY` — выровнять по
/// вертикальному центру переданной точки (иначе текст рисуется вниз от
/// неё).
void _drawText(
  Canvas canvas,
  String text,
  Offset pos,
  Color color,
  double fontSize, {
  TextAlign align = TextAlign.left,
  bool centerY = false,
  bool bold = false,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout();
  final dx = switch (align) {
    TextAlign.right => pos.dx - tp.width,
    TextAlign.center => pos.dx - tp.width / 2,
    _ => pos.dx,
  };
  final dy = centerY || align == TextAlign.right ? pos.dy - tp.height / 2 : pos.dy;
  tp.paint(canvas, Offset(dx, dy));
}
