import 'dart:async';

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../services/local_db_service.dart';

/// Заставка при запуске: буква N в круге с пульсацией и слабым движением
/// колец на чёрном фоне (рисуется кодом — без видео, старт мгновенный).
/// Один цикл [cycleMs]; если приложение под ней ещё не готово и кадры
/// «подвисли», цикл просто повторяется. Один раз за запуск, касание пропускает.
class SplashGate extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final LocalDbService? db;
  const SplashGate({super.key, required this.child, this.enabled = true, this.db});

  static bool _played = false;

  /// Сколько держится заставка (мс).
  static const int maxMs = 1000;

  /// Длительность одного цикла пульсации (мс).
  static const int cycleMs = 1000;

  /// Настройка «Заставка при запуске» (по умолчанию включена).
  static bool isOn(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', ['splash_on']);
    return rows.isEmpty || '${rows.first['hex']}' != '0';
  }

  static void setOn(LocalDbService db, bool v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        ['splash_on', v ? '1' : '0'],
      );

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> with SingleTickerProviderStateMixin {
  late final AnimationController _a;
  bool _showing = false;
  bool _fading = false;
  Timer? _guard;

  @override
  void initState() {
    super.initState();
    _a = AnimationController(vsync: this, duration: const Duration(milliseconds: SplashGate.cycleMs));
    if (!widget.enabled || SplashGate._played) return;
    SplashGate._played = true;
    _showing = true;
    _a.repeat();
    _guard = Timer(const Duration(milliseconds: SplashGate.maxMs), _finish);
  }

  void _finish() {
    if (!mounted || _fading || !_showing) return;
    _guard?.cancel();
    setState(() => _fading = true);
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _showing = false);
      _a.stop();
    });
  }

  @override
  void dispose() {
    _guard?.cancel();
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showing) return widget.child;
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          ignoring: _fading,
          child: AnimatedOpacity(
            opacity: _fading ? 0 : 1,
            duration: const Duration(milliseconds: 280),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _finish,
              child: ColoredBox(
                color: Colors.black,
                child: AnimatedBuilder(
                  animation: _a,
                  builder: (_, __) => CustomPaint(painter: _NexusPulsePainter(_a.value), size: Size.infinite),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Кадр заставки; t — фаза цикла 0..1 (в конце равна началу, шва нет).
class _NexusPulsePainter extends CustomPainter {
  final double t;
  _NexusPulsePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final u = math.min(size.width, size.height);
    final ph = t * 2 * math.pi;
    final pulse = 1 + 0.06 * math.sin(ph);
    const blue = Color(0xFF9FD3FF);
    // слабое движение колец: радиус «дышит», соседние кольца в противофазе
    for (var i = 0; i < 5; i++) {
      final r = u * (0.30 + 0.07 * i) + u * 0.006 * math.sin(ph + i * 1.2);
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, u * 0.0022)
            ..color = blue.withValues(alpha: 0.28 - 0.045 * i));
    }
    // круг с буквой N
    final r0 = u * 0.17 * pulse;
    canvas.drawCircle(
        c,
        r0 * 1.5,
        Paint()
          ..shader = RadialGradient(colors: [blue.withValues(alpha: 0.20), blue.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r0 * 1.5)));
    canvas.drawCircle(
        c,
        r0,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.0, u * 0.008)
          ..color = blue);
    final tp = TextPainter(
      text: TextSpan(
          text: 'N',
          style: TextStyle(color: Colors.white, fontSize: r0 * 1.15, fontWeight: FontWeight.w600, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_NexusPulsePainter o) => o.t != t;
}
