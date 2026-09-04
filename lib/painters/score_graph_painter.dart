import 'package:flutter/material.dart';
import '../models/shot.dart';

/// График "номер выстрела → оценка" (0–10.9 по Y), без внешних
/// библиотек, свой `CustomPainter` (раздел 5 ТЗ).
///
/// По отзыву пользователя ("ничего не понятно, хотя бы деления
/// расчертить надо") добавлены координатная сетка и подписи осей —
/// раньше рисовались только две голые оси без делений, из-за чего
/// линия результатов была не с чем сопоставить.
class ScoreGraphPainter extends CustomPainter {
  final List<Shot> shots;
  final Color lineColor;
  final Color axisColor;

  /// Верх шкалы Y. По умолчанию 10.9 — максимум одного выстрела.
  ///
  /// Параметром это стало из-за реального дефекта на экране "Статистика":
  /// там тем же painter'ом рисуется график "тренировка → СУММА очков"
  /// (например 109.0), а шкала была жёстко зашита на 10.9. Экран
  /// выкручивался тем, что делил суммы на масштаб — в итоге подписи оси
  /// говорили "10", когда на графике была сотня, а точка вылезала над
  /// сеткой. Теперь вызывающий передаёт настоящий максимум и настоящие
  /// значения.
  final double maxY;

  /// Низ шкалы Y.
  ///
  /// Ноль почти всегда бесполезен: на графике результатов выстрелов все
  /// точки жмутся к верхней трети, линия выглядит гладкой, и разницу
  /// между 10.6 и 9.8 не разглядеть. Нижняя граница подтягивается к
  /// худшему результату — и тот же провал становится виден сразу.
  final double minY;

  /// Шаг горизонтальной сетки по Y в тех же единицах, что и `maxY`.
  final double yTickStep;

  /// Подписи по оси X — по одной на точку. `null` — подписываем
  /// порядковым номером, как раньше.
  ///
  /// Появилось из-за графика «динамика по упражнению»: там точка — это
  /// целая тренировка, и подпись «1» под ней не значит ничего.
  /// Пользователю нужна дата.
  final List<String>? xLabels;

  /// Писать подписи X вертикально (снизу вверх).
  ///
  /// Даты в строку не помещаются: «04.09» под каждой из двадцати точек
  /// сливаются в кашу. Повёрнутые занимают по ширине несколько
  /// пикселей, и подписать можно каждую точку.
  final bool verticalXLabels;

  ScoreGraphPainter({
    required this.shots,
    required this.lineColor,
    required this.axisColor,
    this.maxY = 10.9,
    this.minY = 0,
    this.yTickStep = 2,
    this.xLabels,
    this.verticalXLabels = false,
  });

  static const double _leftMargin = 34;
  static const double _bottomMargin = 18;

  /// Сколько места оставить снизу под вертикальные подписи.
  static const double _verticalLabelMargin = 46;
  static const double _topMargin = 8;
  static const double _rightMargin = 10;

  @override
  void paint(Canvas canvas, Size size) {
    const plotLeft = _leftMargin;
    const plotTop = _topMargin;
    final plotRight = size.width - _rightMargin;
    final plotBottom = size.height - (verticalXLabels ? _verticalLabelMargin : _bottomMargin);
    final plotWidth = (plotRight - plotLeft).clamp(1.0, double.infinity);
    final plotHeight = (plotBottom - plotTop).clamp(1.0, double.infinity);

    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.2;

    // Горизонтальные линии сетки с подписями слева. Шаг и верх шкалы
    // задаёт вызывающий — см. комментарий к maxY.
    final span = (maxY - minY).abs() < 1e-9 ? 1.0 : maxY - minY;
    final step = yTickStep <= 0 ? span : yTickStep;
    for (var v = minY; v <= maxY + 1e-9; v += step) {
      final py = plotBottom - ((v - minY) / span) * plotHeight;
      canvas.drawLine(Offset(plotLeft, py), Offset(plotRight, py), gridPaint);
      _drawText(canvas, _formatTick(v), Offset(_leftMargin - 6, py), axisColor, 9, align: TextAlign.right);
    }

    // Оси (жирнее сетки).
    canvas.drawLine(Offset(plotLeft, plotBottom), Offset(plotRight, plotBottom), axisPaint);
    canvas.drawLine(const Offset(plotLeft, plotTop), Offset(plotLeft, plotBottom), axisPaint);

    if (shots.isEmpty) {
      _drawText(canvas, 'Нет выстрелов', Offset((plotLeft + plotRight) / 2, (plotTop + plotBottom) / 2),
          axisColor, 12, align: TextAlign.center);
      return;
    }

    final stepX = shots.length <= 1 ? 0.0 : plotWidth / (shots.length - 1);
    Offset pointAt(int i) {
      final x = shots.length <= 1 ? plotLeft + plotWidth / 2 : plotLeft + i * stepX;
      final ratio = ((shots[i].score - minY) / span).clamp(0.0, 1.0);
      final y = plotBottom - ratio * plotHeight;
      return Offset(x, y);
    }

    // Вертикальные деления — номер выстрела снизу. При большом числе
    // выстрелов подписываем не каждый, чтобы не слипались.
    // Вертикальные подписи узкие, их влезает больше: 20 против 8.
    final maxLabels = verticalXLabels ? 20 : 8;
    final labelStep = shots.length <= 12 ? 1 : (shots.length / maxLabels).ceil();
    for (var i = 0; i < shots.length; i++) {
      if (i % labelStep != 0 && i != shots.length - 1) continue;
      final p = pointAt(i);
      canvas.drawLine(Offset(p.dx, plotBottom), Offset(p.dx, plotBottom + 3), axisPaint);
      final label = xLabels != null && i < xLabels!.length ? xLabels![i] : '${i + 1}';
      if (verticalXLabels) {
        _drawVerticalText(canvas, label, Offset(p.dx, plotBottom + 6), axisColor, 9);
      } else {
        _drawText(canvas, label, Offset(p.dx, plotBottom + 4), axisColor, 9,
            align: TextAlign.center, top: true);
      }
    }

    final path = Path();
    for (var i = 0; i < shots.length; i++) {
      final p = pointAt(i);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    for (var i = 0; i < shots.length; i++) {
      final p = pointAt(i);
      canvas.drawCircle(p, 2.5, Paint()..color = lineColor);
    }
  }

  /// Подпись деления: целые — без хвоста (0, 2, 4), дробный шаг — с
  /// одним знаком (10.9 у графика одного выстрела).
  String _formatTick(double v) {
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  /// Подпись, повёрнутая на 90° против часовой — читается снизу вверх.
  ///
  /// Canvas поворачивается вокруг точки подписи, текст рисуется как
  /// обычный, потом состояние восстанавливается. Смещение по X на
  /// половину высоты строки нужно, чтобы повёрнутая надпись оказалась
  /// по центру своего деления, а не сбоку от него.
  void _drawVerticalText(Canvas canvas, String text, Offset pos, Color color, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(pos.dx + tp.height / 2, pos.dy + tp.width);
    canvas.rotate(-3.141592653589793 / 2);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset pos,
    Color color,
    double fontSize, {
    TextAlign align = TextAlign.left,
    bool top = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = align == TextAlign.right
        ? pos.dx - tp.width
        : align == TextAlign.center
            ? pos.dx - tp.width / 2
            : pos.dx;
    final dy = top ? pos.dy : pos.dy - tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant ScoreGraphPainter oldDelegate) {
    return oldDelegate.shots != shots ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.axisColor != axisColor ||
        oldDelegate.maxY != maxY ||
        oldDelegate.minY != minY ||
        oldDelegate.yTickStep != yTickStep ||
        oldDelegate.verticalXLabels != verticalXLabels ||
        !_sameLabels(oldDelegate.xLabels, xLabels);
  }

  static bool _sameLabels(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
