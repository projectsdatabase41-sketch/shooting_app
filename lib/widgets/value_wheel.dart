import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Горизонтальное «колесо-барабан» для значения 0..1 (вид сбоку, деления сгущаются к краям — эффект 3D).
/// Крутится бесконечно, как колесо выстрелов; значение упирается в 0 и 1 (или идёт по кругу при [wrap]).
class ValueWheel extends StatefulWidget {
  final String label;
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  final bool wrap;
  const ValueWheel({super.key, required this.label, required this.value, required this.onChanged, this.wrap = false});

  @override
  State<ValueWheel> createState() => _ValueWheelState();
}

class _ValueWheelState extends State<ValueWheel> {
  static const _pxPerFull = 420.0; // ход пальца на весь диапазон 0..1
  static const _tickStep = 0.01; // одно деление = 1 %
  double _drag = 0; // накопленный поворот барабана (доли значения), только для картинки

  void _update(DragUpdateDetails d) {
    final dv = d.delta.dx / _pxPerFull;
    var v = widget.value + dv;
    v = widget.wrap ? v - v.floorToDouble() : v.clamp(0.0, 1.0);
    setState(() => _drag += dv);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${widget.label}: ${(widget.value * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _update,
          child: SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: _WheelPainter(
                phase: _drag / _tickStep,
                barrel: cs.surfaceContainerHighest,
                barrelEdge: cs.surfaceContainerLowest,
                tick: cs.onSurfaceVariant,
                marker: AppTheme.accentFor(cs),
                outline: cs.outlineVariant,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final double phase; // в делениях, бесконечный
  final Color barrel, barrelEdge, tick, marker, outline;
  _WheelPainter({required this.phase, required this.barrel, required this.barrelEdge, required this.tick, required this.marker, required this.outline});

  static const _perHalf = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(12));
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [barrelEdge, barrel, barrel, barrelEdge], stops: const [0, 0.32, 0.68, 1]).createShader(rect),
    );
    canvas.save();
    canvas.clipRRect(rr);
    final cx = size.width / 2, radius = size.width / 2, midY = size.height / 2;
    final base = phase.floor();
    final frac = phase - base;
    for (var i = -_perHalf - 1; i <= _perHalf + 1; i++) {
      final theta = (i + frac) * (math.pi / 2) / _perHalf;
      final depth = math.cos(theta);
      if (depth <= 0.02) continue;
      final x = cx + radius * math.sin(theta);
      final major = (i - base) % 5 == 0;
      final half = size.height * (major ? 0.34 : 0.22) * depth;
      canvas.drawLine(
        Offset(x, midY - half),
        Offset(x, midY + half),
        Paint()
          ..color = tick.withValues(alpha: 0.12 + 0.55 * depth * depth)
          ..strokeWidth = major ? 2 : 1.2
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
    canvas.drawLine(Offset(cx, 4), Offset(cx, size.height - 4), Paint()
      ..color = marker.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
    canvas.drawRRect(rr, Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_WheelPainter o) => o.phase != phase || o.barrel != barrel || o.tick != tick || o.marker != marker;
}
