import 'dart:async';

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _v;
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
    _startVideo();
    _guard = Timer(const Duration(milliseconds: SplashGate.maxMs), _finish);
  }

  /// Ролик 1 с в цикле; пока он не готов (или не запустился) — та же картинка,
  /// нарисованная кодом, так что заставка видна сразу.
  Future<void> _startVideo() async {
    try {
      final c = VideoPlayerController.asset('assets/video/splash_loop.mp4');
      _v = c;
      await c.initialize().timeout(const Duration(milliseconds: 800));
      if (!mounted || !_showing) return;
      await c.setVolume(0);
      await c.setLooping(true);
      await c.play();
      setState(() {});
    } catch (_) {
      _v?.dispose();
      _v = null;
    }
  }

  void _finish() {
    if (!mounted || _fading || !_showing) return;
    _guard?.cancel();
    setState(() => _fading = true);
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _showing = false);
      _a.stop();
      _v?.dispose();
      _v = null;
    });
  }

  @override
  void dispose() {
    _guard?.cancel();
    _a.dispose();
    _v?.dispose();
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
                child: _v != null && _v!.value.isInitialized
                    ? SizedBox.expand(
                        child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                                width: _v!.value.size.width, height: _v!.value.size.height, child: VideoPlayer(_v!))))
                    : AnimatedBuilder(
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
  final bool compact; // маленький индикатор ожидания: меньше колец, круг крупнее
  final Color letter;
  _NexusPulsePainter(this.t, {this.compact = false, this.letter = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final u = math.min(size.width, size.height);
    final ph = t * 2 * math.pi;
    final pulse = 1 + 0.06 * math.sin(ph);
    const blue = Color(0xFF9FD3FF);
    // слабое движение колец: радиус «дышит», соседние кольца в противофазе
    for (var i = 0; i < (compact ? 2 : 5); i++) {
      final r = u * (compact ? 0.30 + 0.09 * i : 0.30 + 0.07 * i) + u * 0.006 * math.sin(ph + i * 1.2);
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, u * 0.0022)
            ..color = blue.withValues(alpha: 0.28 - 0.045 * i));
    }
    // круг с буквой N
    final r0 = u * (compact ? 0.24 : 0.17) * pulse;
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
          style: TextStyle(color: letter, fontSize: r0 * 1.15, fontWeight: FontWeight.w600, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    // заглавная N: центр по высоте капители, а не по строке (иначе визуально выше/ниже)
    final base = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final cap = r0 * 1.15 * 0.71;
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy + cap / 2 - base));
  }

  @override
  bool shouldRepaint(_NexusPulsePainter o) => o.t != t;
}

/// Индикатор ожидания: та же пульсирующая N в круге (вместо колеса загрузки).
class NexusPulse extends StatefulWidget {
  final double size;
  const NexusPulse({super.key, this.size = 96});

  @override
  State<NexusPulse> createState() => _NexusPulseState();
}

class _NexusPulseState extends State<NexusPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: SplashGate.cycleMs))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final letter = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _a,
          builder: (_, __) =>
              CustomPaint(painter: _NexusPulsePainter(_a.value, compact: true, letter: letter), size: Size.infinite),
        ),
      ),
    );
  }
}
