import 'package:flutter/material.dart';

/// Страница раздела, открытая с плитки главного экрана: на фоне — большой
/// блёклый значок этой плитки и кольца мишени (плитка «растворилась» в фон).
/// Сам экран раздела прозрачный поверх этого фона.
class TileBackdropPage extends StatelessWidget {
  final IconData icon;
  final Widget child;
  const TileBackdropPage({super.key, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = theme.scaffoldBackgroundColor;
    final tint = theme.colorScheme.primary;
    final size = MediaQuery.sizeOf(context);
    return Stack(fit: StackFit.expand, children: [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [base, Color.lerp(base, tint, dark ? 0.12 : 0.10)!],
          ),
        ),
      ),
      CustomPaint(painter: _RingsPainter(tint.withValues(alpha: dark ? 0.10 : 0.09))),
      Align(
        alignment: const Alignment(0.0, -0.15),
        child: Icon(icon, size: size.shortestSide * 0.85, color: tint.withValues(alpha: dark ? 0.07 : 0.06)),
      ),
      // сам раздел — поверх, с прозрачным фоном экрана
      Theme(
        data: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: child,
      ),
    ]);
  }
}

class _RingsPainter extends CustomPainter {
  final Color color;
  _RingsPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.42);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 1; i <= 6; i++) {
      p.color = color.withValues(alpha: color.a * (1 - i * 0.12));
      canvas.drawCircle(c, size.width * 0.14 * i, p);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter o) => o.color != color;
}
