import 'dart:async';
import 'dart:math' as math;

import 'glass_route.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../i18n/i18n.dart';

/// Подсветка при съёмке на фронтальную камеру: экран по краям светится как
/// виньетка. Настройки: яркость, теплота (от холодного белого к тёплому) или
/// свой цвет (RGB — оттенок ползунком).
class SelfieLightState extends ChangeNotifier {
  bool on = false;

  /// Плавность включения: 0 → 1 за ~2,5 с (яркость растёт постепенно, не резко).
  double level = 1;
  Timer? _fade;

  void turnOn() {
    if (on) return;
    on = true;
    level = 0;
    _fade?.cancel();
    _fade = Timer.periodic(const Duration(milliseconds: 50), (t) {
      level = (level + 0.02).clamp(0.0, 1.0);
      notifyListeners();
      if (level >= 1) t.cancel();
    });
    _syncScreen();
    notifyListeners();
  }

  void turnOff() {
    _fade?.cancel();
    on = false;
    level = 1;
    _syncScreen();
    notifyListeners();
  }

  void toggle() => on ? turnOff() : turnOn();

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  double brightness = 0.7; // 0..1
  double warmth = 0.4; // 0 — холодный, 1 — тёплый
  bool rgb = false;
  double hue = 200; // 0..360, только в режиме RGB

  void update(void Function() f) {
    f();
    _syncScreen();
    notifyListeners();
  }

  /// Пока подсветка включена, яркость экрана выкручивается на максимум (на фронтальной камере вспышки нет,
  /// светит сам экран); при выключении возвращается прежняя. На вебе системной яркости нет — только свечение рамки.
  bool _maxed = false;
  Future<void> _syncScreen() async {
    if (kIsWeb) return;
    try {
      if (on && !_maxed) {
        _maxed = true;
        await ScreenBrightness().setApplicationScreenBrightness(1.0);
      } else if (!on && _maxed) {
        _maxed = false;
        await ScreenBrightness().resetApplicationScreenBrightness();
      }
    } catch (_) {
      // яркость недоступна на этом устройстве — остаётся свечение рамки
    }
  }

  /// Вернуть яркость при закрытии экрана съёмки.
  void release() {
    if (_maxed) {
      on = false;
      _syncScreen();
    }
  }

  Color get color {
    if (rgb) return HSVColor.fromAHSV(1, hue, 0.85, 1).toColor();
    // холодный белый (200,225,255) → тёплый (255,190,120)
    return Color.lerp(const Color(0xFFC8E1FF), const Color(0xFFFFBE78), warmth)!;
  }
}

/// Сама виньетка — класть поверх изображения, касания не перехватывает.
class SelfieLightOverlay extends StatelessWidget {
  final SelfieLightState light;
  const SelfieLightOverlay({super.key, required this.light});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: light,
        builder: (context, _) {
          if (!light.on) return const SizedBox.shrink();
          final c = light.color;
          return IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.95,
                  colors: [c.withValues(alpha: 0.04 * light.brightness * light.level), c.withValues(alpha: 0.4 * light.brightness * light.level), c.withValues(alpha: light.brightness * light.level)],
                  stops: const [0.3, 0.62, 1.0],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      );
}

/// Панель настроек подсветки.
Future<void> showSelfieLightSheet(BuildContext context, SelfieLightState light) {
  return showGlassSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: light,
      builder: (ctx, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Подсветка экрана')),
              value: light.on,
              onChanged: (v) => light.update(() => light.on = v),
            ),
            Text(tr('Яркость'), style: Theme.of(ctx).textTheme.labelLarge),
            Slider(value: light.brightness, onChanged: (v) => light.update(() => light.brightness = v)),
            Row(children: [
              Expanded(child: Text(light.rgb ? tr('Цвет') : tr('Теплота'), style: Theme.of(ctx).textTheme.labelLarge)),
              TextButton.icon(
                onPressed: () => light.update(() => light.rgb = !light.rgb),
                icon: Icon(light.rgb ? Icons.wb_sunny_outlined : Icons.palette_outlined, size: 18),
                label: Text(light.rgb ? tr('Белый') : 'RGB'),
              ),
            ]),
            if (light.rgb)
              Slider(
                min: 0,
                max: 360,
                value: light.hue,
                activeColor: light.color,
                onChanged: (v) => light.update(() => light.hue = v),
              )
            else
              Slider(value: light.warmth, onChanged: (v) => light.update(() => light.warmth = v)),
          ]),
        ),
      ),
    ),
  );
}


/// Управление подсветкой жестами, без окон: свайп вверх/вниз — яркость, влево/вправо — теплота (в режиме RGB — цвет).
/// Работает только пока подсветка включена; выключенной — жесты не перехватываются.
class SelfieLightGestures extends StatefulWidget {
  final SelfieLightState light;
  final Widget child;
  const SelfieLightGestures({super.key, required this.light, required this.child});

  @override
  State<SelfieLightGestures> createState() => _SelfieLightGesturesState();
}

class _SelfieLightGesturesState extends State<SelfieLightGestures> {
  bool? _vertical; // ось жеста определяется по первому заметному сдвигу
  Offset _acc = Offset.zero;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.light,
        builder: (context, _) {
          if (!widget.light.on) return widget.child;
          final size = MediaQuery.sizeOf(context);
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) {
              _vertical = null;
              _acc = Offset.zero;
            },
            onPanUpdate: (d) {
              _acc += d.delta;
              _vertical ??= (_acc.distance > 12) ? _acc.dy.abs() > _acc.dx.abs() : null;
              final l = widget.light;
              if (_vertical == true) {
                l.update(() => l.brightness = (l.brightness - d.delta.dy / (size.height * 0.5)).clamp(0.05, 1.0));
              } else if (_vertical == false) {
                // справа налево — теплее, слева направо — холоднее
                if (l.rgb) {
                  l.update(() => l.hue = (l.hue + d.delta.dx * 0.8) % 360);
                } else {
                  l.update(() => l.warmth = (l.warmth - d.delta.dx / (size.width * 0.8)).clamp(0.0, 1.0));
                }
              }
            },
            child: widget.child,
          );
        },
      );
}

/// Кнопка: короткое нажатие — [onTap]; удержание [holdFor] (2 с по умолчанию) — [onHold].
class HoldButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onHold;
  final Duration holdFor;
  const HoldButton({super.key, required this.child, required this.onTap, required this.onHold, this.holdFor = const Duration(seconds: 2)});

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  Timer? _t;
  bool _fired = false;
  Offset _down = Offset.zero;
  bool _moved = false;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _fired = false;
          _moved = false;
          _down = e.position;
          _t?.cancel();
          _t = Timer(widget.holdFor, () {
            _fired = true;
            widget.onHold();
          });
        },
        onPointerMove: (e) {
          if ((e.position - _down).distance > 24) {
            _moved = true;
            _t?.cancel();
          }
        },
        onPointerUp: (_) {
          _t?.cancel();
          if (!_fired && !_moved) widget.onTap();
        },
        onPointerCancel: (_) => _t?.cancel(),
        child: IgnorePointer(child: widget.child),
      );
}

/// Кольцо выбора цвета подсветки вокруг кружка: градиент оттенков и бегунок, который можно двигать по кругу.
class HueRing extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  const HueRing({super.key, required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        void set(Offset p) {
          final c = Offset(size.width / 2, size.height / 2);
          final a = math.atan2(p.dy - c.dy, p.dx - c.dx); // 0 — вправо, по часовой
          onChanged(((a * 180 / math.pi) + 360) % 360);
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (d) => set(d.localPosition),
          onPanUpdate: (d) => set(d.localPosition),
          onTapDown: (d) => set(d.localPosition),
          child: CustomPaint(size: size, painter: _RingPainter(hue)),
        );
      });
}

class _RingPainter extends CustomPainter {
  final double hue;
  _RingPainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2 - 5;
    final rect = Rect.fromCircle(center: c, radius: r);
    final colors = [for (var h = 0; h <= 360; h += 30) HSVColor.fromAHSV(1, h.toDouble(), 0.85, 1).toColor()];
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..shader = SweepGradient(colors: colors).createShader(rect));
    final a = hue * math.pi / 180;
    final k = c + Offset(math.cos(a), math.sin(a)) * r;
    canvas.drawCircle(k, 13, Paint()..color = Colors.white);
    canvas.drawCircle(k, 9, Paint()..color = HSVColor.fromAHSV(1, hue, 0.85, 1).toColor());
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.hue != hue;
}

/// Полоса выбора цвета для экрана звонка (линейный градиент с бегунком).
class HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  const HueBar({super.key, required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, box) {
        void set(Offset p) => onChanged((p.dx / box.maxWidth).clamp(0.0, 1.0) * 360);
        final colors = [for (var h = 0; h <= 360; h += 30) HSVColor.fromAHSV(1, h.toDouble(), 0.85, 1).toColor()];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => set(d.localPosition),
          onPanUpdate: (d) => set(d.localPosition),
          onTapDown: (d) => set(d.localPosition),
          child: SizedBox(
            height: 36,
            child: Stack(alignment: Alignment.centerLeft, children: [
              Container(height: 8, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: LinearGradient(colors: colors))),
              Positioned(
                left: (hue / 360) * (box.maxWidth - 26),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: HSVColor.fromAHSV(1, hue, 0.85, 1).toColor(), border: Border.all(color: Colors.white, width: 3)),
                ),
              ),
            ]),
          ),
        );
      });
}
