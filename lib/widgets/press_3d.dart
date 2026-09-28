import 'package:flutter/material.dart';

/// Объёмная карточка: градиент «сверху светлее», тень снизу и наклон «от
/// пальца» при нажатии (как плитки на панели собеседника). Без [onTap] —
/// просто выпуклая карточка без реакции.
class Press3D extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Базовый цвет; по умолчанию — поверхность темы.
  final Color? color;

  /// Цветная кромка (например, цвет режима ступени).
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final double radius;

  const Press3D({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.accent,
    this.padding = const EdgeInsets.all(12),
    this.radius = 16,
  });

  @override
  State<Press3D> createState() => _Press3DState();
}

class _Press3DState extends State<Press3D> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.color ?? cs.surfaceContainerHigh;
    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _down ? 1 : 0),
        duration: const Duration(milliseconds: 120),
        builder: (context, t, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateX(0.18 * t)
            ..scaleByDouble(1 - 0.02 * t, 1 - 0.02 * t, 1, 1),
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(base, Colors.white, 0.07)!, Color.lerp(base, Colors.black, 0.10)!],
              ),
              border: widget.accent == null ? null : Border.all(color: widget.accent!.withValues(alpha: 0.55), width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 12 - 7 * t,
                  offset: Offset(0, 6 - 4 * t),
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
