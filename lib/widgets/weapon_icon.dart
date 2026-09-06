import 'package:flutter/material.dart';

import '../models/target_face.dart';

/// Иконка оружия — винтовка или пистолет, по коду мишени
/// (`TargetFace.weaponRu`). В стандартном наборе Material Icons таких
/// иконок нет вовсе, поэтому рисуются сами, простым силуэтом — как и
/// вся остальная графика в приложении (мишень, кольца).
class WeaponIcon extends StatelessWidget {
  final TargetFace face;
  final double size;
  final Color? color;

  const WeaponIcon({super.key, required this.face, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return CustomPaint(
      size: Size.square(size),
      painter: _WeaponPainter(isRifle: face.weaponRu == 'винтовка', color: resolvedColor),
    );
  }
}

class _WeaponPainter extends CustomPainter {
  final bool isRifle;
  final Color color;

  const _WeaponPainter({required this.isRifle, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Обводка, а не заливка: у иконки высотой 14-20px залитые фигуры
    // сливаются в блямбу, а тонкая линия сохраняет форму читаемой —
    // тем же способом, каким устроены минималистичные наборы line-icon.
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.14
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * w, y * h);

    if (isRifle) {
      // Длинный ствол на всю ширину, приклад — угол вниз в конце,
      // рукоять — короткий штрих посередине. Силуэт длинный и низкий.
      final path = Path()
        ..moveTo(p(0.02, 0.40).dx, p(0.02, 0.40).dy)
        ..lineTo(p(0.80, 0.40).dx, p(0.80, 0.40).dy)
        ..lineTo(p(0.96, 0.85).dx, p(0.96, 0.85).dy);
      canvas.drawPath(path, paint);
      canvas.drawLine(p(0.45, 0.40), p(0.45, 0.62), paint);
    } else {
      // Короткий ствол + рукоять уходит вниз-назад — весь силуэт
      // компактный, укладывается в меньшую половину высоты по ширине.
      final path = Path()
        ..moveTo(p(0.18, 0.42).dx, p(0.18, 0.42).dy)
        ..lineTo(p(0.88, 0.42).dx, p(0.88, 0.42).dy);
      canvas.drawPath(path, paint);
      canvas.drawLine(p(0.28, 0.42), p(0.20, 0.88), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WeaponPainter oldDelegate) =>
      oldDelegate.isRifle != isRifle || oldDelegate.color != color;
}
