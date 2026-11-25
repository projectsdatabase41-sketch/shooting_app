import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Положение стрелка для значка упражнения (отзыв a69f8d83).
///
/// [allThree] — дисциплина из трёх положений: рисуются три фигуры в один
/// ряд по глубине — лёжа впереди, с колена за ним, стоя сзади.
enum StanceKind { standing, kneeling, prone, allThree }

/// Оружие: винтовка — длинный ствол; пистолет — короткий, у вытянутой руки.
enum WeaponKind { rifle, pistol }

/// Декоративный силуэт стрелка в изготовке: голова, корпус, руки, оружие —
/// простыми формами (окружности и скруглённые линии), без деталей лица и
/// пальцев. Цвет задаёт вызывающий — цвет плитки/кнопки из персонализации.
///
/// Рисунок строится в нормализованных координатах 0..1 и масштабируется
/// по [size]: смена размеров не требует правки геометрии, радиусы и толщина
/// линий — положительные константы, отрицательных значений не возникает;
/// при size <= 0 ничего не рисуется.
class StanceIcon extends StatelessWidget {
  final StanceKind stance;
  final WeaponKind weapon;
  final Color color;

  /// Сторона квадратного значка, логические пиксели.
  final double size;

  /// Смысловая подпись для скринридеров — формирует вызывающий.
  final String? semanticLabel;

  const StanceIcon({
    super.key,
    required this.stance,
    required this.weapon,
    required this.color,
    this.size = 24,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget icon = CustomPaint(
      size: Size.square(size),
      painter: _StancePainter(stance: stance, weapon: weapon, color: color),
    );
    if (semanticLabel != null) {
      icon = Semantics(label: semanticLabel, child: icon);
    }
    return SizedBox(width: size, height: size, child: icon);
  }
}

class _StancePainter extends CustomPainter {
  final StanceKind stance;
  final WeaponKind weapon;
  final Color color;

  const _StancePainter({
    required this.stance,
    required this.weapon,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    if (s <= 0) return;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (stance) {
      case StanceKind.standing:
        _drawStanding(canvas, fill, stroke, 0, 0, s);
      case StanceKind.kneeling:
        _drawKneeling(canvas, fill, stroke, 0, 0, s);
      case StanceKind.prone:
        _drawProne(canvas, fill, stroke, 0, 0, s);
      case StanceKind.allThree:
        // Ряд по глубине: стоя сзади (выше и мельче) рисуем первым, с колена
        // в середине, лёжа впереди (ниже и крупнее) — последним. Все фигуры
        // в одном цвете, перекрытие допустимо.
        _drawStanding(canvas, fill, stroke, 0.64 * s, 0, 0.32 * s);
        _drawKneeling(canvas, fill, stroke, 0.30 * s, 0.30 * s, 0.36 * s);
        _drawProne(canvas, fill, stroke, 0, 0.36 * s, 0.64 * s);
    }
  }

  /// Стоя с винтовкой/пистолетом.
  void _drawStanding(Canvas canvas, Paint fill, Paint stroke, double dx, double dy, double sc) {
    if (sc <= 0) return;
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(sc);
    if (weapon == WeaponKind.rifle) {
      // Винтовка: длинный ствол поперёк корпуса, дульной частью вперёд.
      _line(canvas, stroke, 0.14, 0.46, 0.88, 0.34, 0.08);
      // Рука, придерживающая оружие.
      _line(canvas, stroke, 0.50, 0.34, 0.70, 0.36, 0.10);
    } else {
      // Пистолет: вытянутая вперёд рука и короткое толстое оружие у кисти.
      _line(canvas, stroke, 0.50, 0.34, 0.84, 0.26, 0.11);
      _line(canvas, stroke, 0.84, 0.26, 0.98, 0.235, 0.14);
    }
    canvas.drawCircle(const Offset(0.50, 0.15), 0.10, fill); // голова
    _line(canvas, stroke, 0.50, 0.29, 0.50, 0.60, 0.17); // корпус
    _line(canvas, stroke, 0.50, 0.58, 0.41, 0.94, 0.12); // ноги
    _line(canvas, stroke, 0.50, 0.58, 0.59, 0.94, 0.12);
    canvas.restore();
  }

  /// С колена: корпус чуть вперёд, передняя нога согнута, задняя на колене.
  void _drawKneeling(Canvas canvas, Paint fill, Paint stroke, double dx, double dy, double sc) {
    if (sc <= 0) return;
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(sc);
    if (weapon == WeaponKind.rifle) {
      // Винтовка лежит на руке, локоть опирается на колено.
      _line(canvas, stroke, 0.30, 0.64, 0.92, 0.48, 0.08);
      _line(canvas, stroke, 0.56, 0.38, 0.72, 0.60, 0.10);
    } else {
      _line(canvas, stroke, 0.56, 0.38, 0.90, 0.30, 0.11);
      _line(canvas, stroke, 0.90, 0.30, 0.99, 0.275, 0.14);
    }
    canvas.drawCircle(const Offset(0.56, 0.22), 0.10, fill); // голова
    _line(canvas, stroke, 0.48, 0.72, 0.56, 0.35, 0.17); // корпус
    _line(canvas, stroke, 0.48, 0.72, 0.72, 0.62, 0.12); // бедро передней
    _line(canvas, stroke, 0.72, 0.62, 0.72, 0.94, 0.12); // голень передней
    _line(canvas, stroke, 0.48, 0.72, 0.30, 0.94, 0.12); // задняя на колене
    canvas.restore();
  }

  /// Лёжа: корпус вдоль земли головой вперёд (вправо), оружие впереди.
  void _drawProne(Canvas canvas, Paint fill, Paint stroke, double dx, double dy, double sc) {
    if (sc <= 0) return;
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(sc);
    if (weapon == WeaponKind.rifle) {
      _line(canvas, stroke, 0.70, 0.58, 0.99, 0.56, 0.08);
      // Локоть упирается в землю под оружием.
      _line(canvas, stroke, 0.62, 0.74, 0.72, 0.62, 0.10);
    } else {
      _line(canvas, stroke, 0.72, 0.68, 0.92, 0.60, 0.11);
      _line(canvas, stroke, 0.92, 0.60, 1.00, 0.575, 0.14);
    }
    canvas.drawCircle(const Offset(0.80, 0.64), 0.10, fill); // голова
    _line(canvas, stroke, 0.70, 0.70, 0.28, 0.78, 0.17); // корпус
    _line(canvas, stroke, 0.28, 0.78, 0.05, 0.86, 0.13); // ноги
    canvas.restore();
  }

  void _line(Canvas canvas, Paint stroke, double x1, double y1, double x2, double y2, double w) {
    canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke..strokeWidth = w);
  }

  @override
  bool shouldRepaint(_StancePainter oldDelegate) =>
      oldDelegate.stance != stance ||
      oldDelegate.weapon != weapon ||
      oldDelegate.color != color;
}
