import 'package:flutter/material.dart';

/// Графический ключ: сетка 3×3, палец проводит линию через точки. Результат — строка из номеров
/// точек (0…8 слева направо, сверху вниз) в порядке прохода.
class PatternPad extends StatefulWidget {
  /// Вызывается, когда палец отпущен; [pattern] — номера точек подряд (может быть короче нужного —
  /// проверку длины делает вызывающий).
  final ValueChanged<String> onComplete;
  final double size;
  final bool error;

  /// false — идёт проверка: касания игнорируются.
  final bool enabled;
  const PatternPad({super.key, required this.onComplete, this.size = 260, this.error = false, this.enabled = true});

  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  final List<int> _path = [];
  Offset? _finger;

  Offset _center(int i) {
    final cell = widget.size / 3;
    return Offset((i % 3) * cell + cell / 2, (i ~/ 3) * cell + cell / 2);
  }

  void _hit(Offset p) {
    _finger = p;
    for (var i = 0; i < 9; i++) {
      if ((p - _center(i)).distance < widget.size / 3 * 0.32 && !_path.contains(i)) {
        _path.add(i);
        break;
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.error ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      ignoring: !widget.enabled,
      child: SizedBox(
      width: widget.size,
      height: widget.size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _path.clear();
          _hit(d.localPosition);
        },
        onPanUpdate: (d) => _hit(d.localPosition),
        onPanEnd: (_) {
          final result = _path.join();
          setState(() {
            _path.clear();
            _finger = null;
          });
          if (result.isNotEmpty) widget.onComplete(result);
        },
        child: CustomPaint(
          painter: _PatternPainter(path: List.of(_path), finger: _finger, centers: [for (var i = 0; i < 9; i++) _center(i)], color: color, dot: Theme.of(context).colorScheme.outline),
        ),
      ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  final List<int> path;
  final Offset? finger;
  final List<Offset> centers;
  final Color color;
  final Color dot;
  _PatternPainter({required this.path, required this.finger, required this.centers, required this.color, required this.dot});

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < path.length; i++) {
      canvas.drawLine(centers[path[i - 1]], centers[path[i]], line);
    }
    if (path.isNotEmpty && finger != null) canvas.drawLine(centers[path.last], finger!, line);
    for (var i = 0; i < 9; i++) {
      final on = path.contains(i);
      canvas.drawCircle(centers[i], on ? 14 : 9, Paint()..color = on ? color : dot.withValues(alpha: 0.6));
      if (on) canvas.drawCircle(centers[i], 24, Paint()..color = color.withValues(alpha: 0.18));
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => true;
}
