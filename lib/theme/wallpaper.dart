import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'backdrop_tint.dart';

/// Обои из слоёв, как два листа бумаги:
///  • ЗАДНИЙ лист — цветной (градиент со свечением), его видно только в прорезях;
///  • ПЕРЕДНИЙ лист — основной цвет фона с вырезами (кольца, узоры, кубок, пьедестал): в вырезах
///    просвечивает задний лист; у переднего листа есть прозрачность, у заднего — размытие;
///  • ВИНЬЕТКА — затемнение к краям.
/// Все цвета строятся из одного оттенка (см. [BackdropTint]), поэтому обои, плитки и кнопки
/// перекрашиваются вместе и без перерисованных картинок.
class WallpaperStyle {
  final Color front; // цвет переднего листа
  final Color backDark; // задний лист: тёмная часть градиента
  final Color backGlow; // задний лист: свечение в центре прорезей
  final double frontOpacity; // 0..1
  final double vignette; // 0..1
  final double blur; // размытие заднего листа, px
  final String eraseShape;
  final double eraseSoft;
  final double eraseStrength;
  final double eraseSize;
  const WallpaperStyle({
    this.eraseShape = 'none',
    this.eraseSoft = 0.6,
    this.eraseStrength = 0.7,
    this.eraseSize = 0.8,
    required this.front,
    required this.backDark,
    required this.backGlow,
    required this.frontOpacity,
    required this.vignette,
    required this.blur,
  });

  /// Стиль для [kind]. Золотые обои («Чемпионы», «Финалы») не следуют общему оттенку.
  factory WallpaperStyle.of(String kind, Brightness b) {
    final dark = b == Brightness.dark;
    final gold = BackdropTint.exempt.contains(kind);
    final hue = gold ? 42.0 : BackdropTint.effectiveHue();
    final s = gold ? 1.0 : BackdropTint.effectiveSat();
    double q(double v) => (v * s).clamp(0.0, 1.0).toDouble();
    Color hsl(double sat, double l) => HSLColor.fromAHSL(1, hue % 360, q(sat), l).toColor();
    final es = BackdropTint.eraseShape;
    final eSoft = BackdropTint.eraseSoft, eStr = BackdropTint.eraseStrength, eSize = BackdropTint.eraseSize;
    return dark
        ? WallpaperStyle(
            eraseShape: es,
            eraseSoft: eSoft,
            eraseStrength: eStr,
            eraseSize: eSize,
            front: hsl(gold ? 0.35 : 0.28, 0.045),
            backDark: hsl(0.62, 0.16),
            backGlow: hsl(0.92, gold ? 0.58 : 0.60),
            frontOpacity: BackdropTint.frontOpacity,
            vignette: BackdropTint.vignette,
            blur: BackdropTint.blur,
          )
        : WallpaperStyle(
            eraseShape: es,
            eraseSoft: eSoft,
            eraseStrength: eStr,
            eraseSize: eSize,
            front: hsl(0.28, 0.975),
            backDark: hsl(0.55, 0.58),
            backGlow: hsl(0.85, gold ? 0.40 : 0.46),
            frontOpacity: BackdropTint.frontOpacity,
            vignette: BackdropTint.vignette * 0.6,
            blur: BackdropTint.blur,
          );
  }
}

/// Обои экрана. [kind]: home | messenger | settings | ai | champions | finals.
class Wallpaper extends StatelessWidget {
  final String kind;
  const Wallpaper({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // Перерисовка — только при смене параметров оттенка/слоёв, не на каждом кадре.
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: BackdropTint.revision,
        builder: (_, __, ___) => CustomPaint(
          painter: WallpaperPainter(kind, WallpaperStyle.of(kind, b), b),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class WallpaperPainter extends CustomPainter {
  final String kind;
  final WallpaperStyle style;
  final Brightness brightness;
  WallpaperPainter(this.kind, this.style, this.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final rect = Offset.zero & size;
    final glow = _glowCenter(size);

    // 1. Задний лист (виден только в прорезях): градиент со свечением; может быть размыт.
    if (style.blur > 0.1) {
      canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: style.blur, sigmaY: style.blur, tileMode: TileMode.clamp));
    } else {
      canvas.save();
    }
    canvas.drawRect(rect, Paint()..color = style.backDark);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(glow, math.max(w, h) * 0.95, [style.backGlow, style.backGlow.withValues(alpha: 0)], [0.0, 1.0]),
    );
    canvas.restore();

    // 2. Передний лист с вырезами: вырезы стираются режимом clear внутри отдельного слоя.
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, Paint()..color = style.front.withValues(alpha: style.frontOpacity));
    _cutouts(canvas, size);
    _erase(canvas, size, glow);
    canvas.restore();

    // 3. Виньетка: затемнение к краям.
    if (style.vignette > 0.01) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            rect.center,
            math.max(w, h) * 0.78,
            [Colors.transparent, Colors.black.withValues(alpha: 0.65 * style.vignette)],
            [0.55, 1.0],
          ),
      );
    }
  }

  Offset _glowCenter(Size s) => switch (kind) {
        'settings' => Offset(s.width / 2, 0),
        'ai' => Offset(s.width / 2, s.height * 0.22),
        'champions' => Offset(s.width / 2, s.height * 0.36),
        'finals' => Offset(s.width / 2, s.height * 0.24),
        'messenger' => Offset(s.width * 0.7, s.height * 0.25),
        _ => Offset(s.width / 2, s.height * 0.40),
      };

  /// «Стирание» переднего листа выбранной фигурой/стороной с мягким краем: чем сильнее, тем больше
  /// просвечивает задний лист. Рисуется режимом dstOut (стирает пропорционально прозрачности).
  void _erase(Canvas canvas, Size s, Offset c) {
    final shape = style.eraseShape;
    if (shape == 'none' || style.eraseStrength < 0.01) return;
    final w = s.width, h = s.height, m = math.min(w, h);
    final k = style.eraseSize, soft = style.eraseSoft, a = style.eraseStrength;
    final color = Colors.black.withValues(alpha: a);
    Paint fill() {
      final p = Paint()
        ..color = color
        ..blendMode = BlendMode.dstOut
        ..isAntiAlias = true;
      final sigma = soft * m * 0.10;
      if (sigma > 0.3) p.maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);
      return p;
    }

    Paint ramp(Offset from, Offset to) => Paint()
      ..blendMode = BlendMode.dstOut
      ..shader = ui.Gradient.linear(from, to, [color, color.withValues(alpha: 0)], [0.0, 0.25 + 0.75 * soft > 1 ? 1.0 : 0.25 + 0.75 * soft]);

    switch (shape) {
      case 'left':
        canvas.drawRect(Offset.zero & s, ramp(Offset(0, 0), Offset(w * k * 0.9, 0)));
      case 'right':
        canvas.drawRect(Offset.zero & s, ramp(Offset(w, 0), Offset(w - w * k * 0.9, 0)));
      case 'top':
        canvas.drawRect(Offset.zero & s, ramp(Offset(0, 0), Offset(0, h * k * 0.6)));
      case 'bottom':
        canvas.drawRect(Offset.zero & s, ramp(Offset(0, h), Offset(0, h - h * k * 0.6)));
      case 'circle':
        canvas.drawCircle(c, m * 0.42 * k, fill());
      case 'square':
        canvas.drawRect(Rect.fromCenter(center: c, width: m * 0.72 * k, height: m * 0.72 * k), fill());
      case 'band':
        canvas.drawRect(Rect.fromCenter(center: c, width: w * 1.2, height: h * 0.16 * k), fill());
      case 'triangle':
        final r = m * 0.46 * k;
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - r)
            ..lineTo(c.dx + r * 0.87, c.dy + r * 0.5)
            ..lineTo(c.dx - r * 0.87, c.dy + r * 0.5)
            ..close(),
          fill(),
        );
      case 'star':
        final r = m * 0.46 * k;
        final path = Path();
        for (var i = 0; i < 10; i++) {
          final ang = -math.pi / 2 + i * math.pi / 5;
          final rr = i.isEven ? r : r * 0.42;
          final pt = Offset(c.dx + rr * math.cos(ang), c.dy + rr * math.sin(ang));
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path..close(), fill());
    }
  }

  Paint _slit(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..blendMode = BlendMode.clear
    ..isAntiAlias = true;

  Paint get _hole => Paint()
    ..style = PaintingStyle.fill
    ..blendMode = BlendMode.clear
    ..isAntiAlias = true;

  void _rings(Canvas canvas, Offset c, Size s, Iterable<int> ks, double slit) {
    final step = s.width * 0.14;
    final p = _slit(slit);
    for (final k in ks) {
      canvas.drawCircle(c, step * k, p);
    }
  }

  void _cutouts(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final slit = math.max(2.0, w * 0.0042);
    switch (kind) {
      case 'settings':
        _rings(canvas, Offset(w / 2, 0), s, List.generate(10, (i) => i + 2), slit);
      case 'ai':
        _rings(canvas, Offset(w / 2, h * 0.22), s, List.generate(7, (i) => i + 1), slit * 1.2);
      case 'messenger':
        _pattern(canvas, s, slit);
      case 'champions':
        _rings(canvas, Offset(w / 2, h * 0.36), s, List.generate(7, (i) => i + 2), slit * 0.9);
        _trophy(canvas, s, slit * 1.6);
      case 'finals':
        _rings(canvas, Offset(w / 2, h * 0.24), s, List.generate(7, (i) => i + 1), slit * 0.9);
        _podium(canvas, s, slit * 1.6);
      default: // home
        _rings(canvas, Offset(w / 2, h * 0.40), s, List.generate(8, (i) => i + 1), slit);
    }
  }

  /// Узор мессенджера: мишени, прицелы, ромбы и кольца в шахматном порядке.
  void _pattern(Canvas canvas, Size s, double slit) {
    final cell = s.width * 0.15;
    final u = cell * 0.17;
    final p = _slit(math.max(1.5, slit * 0.8));
    final rnd = math.Random(3);
    for (var row = 0; row < s.height / cell + 2; row++) {
      for (var c = 0; c < s.width / cell + 2; c++) {
        final x = c * cell + (row.isOdd ? cell / 2 : 0);
        final y = row * cell;
        final k = (row * 3 + c * 5 + rnd.nextInt(2)) % 6;
        switch (k) {
          case 0:
            canvas.drawCircle(Offset(x, y), u, p);
            canvas.drawCircle(Offset(x, y), u * 0.55, p);
          case 1:
            canvas.drawLine(Offset(x - u, y), Offset(x + u, y), p);
            canvas.drawLine(Offset(x, y - u), Offset(x, y + u), p);
          case 2:
            canvas.drawCircle(Offset(x, y), u * 0.45, p);
          case 3:
            canvas.drawCircle(Offset(x, y), u * 0.8, p);
          case 4:
            final r = u * 0.8;
            canvas.drawPath(Path()..moveTo(x, y - r)..lineTo(x + r, y)..lineTo(x, y + r)..lineTo(x - r, y)..close(), p);
          default:
            canvas.drawLine(Offset(x - u * 0.6, y), Offset(x + u * 0.6, y), p);
            canvas.drawLine(Offset(x, y - u * 0.6), Offset(x, y + u * 0.6), p);
        }
      }
    }
  }

  /// Кубок: контур чаши с ручками, ножка, основание и звезда — вырезы.
  void _trophy(Canvas canvas, Size s, double slit) {
    final w = s.width, h = s.height;
    final cx = w / 2, top = h * 0.25, cw = w * 0.34, ch = h * 0.17;
    final p = _slit(slit);
    final bowl = Path()..moveTo(cx - cw / 2, top);
    for (var i = 0; i <= 40; i++) {
      final t = i / 40;
      bowl.lineTo(cx - (cw / 2) * math.sqrt(1 - math.pow(t, 2.3)), top + ch * t);
    }
    for (var i = 40; i >= 0; i--) {
      final t = i / 40;
      bowl.lineTo(cx + (cw / 2) * math.sqrt(1 - math.pow(t, 2.3)), top + ch * t);
    }
    bowl.close();
    canvas.drawPath(bowl, p);
    for (final sx in [-1.0, 1.0]) {
      final xo = cx + sx * cw / 2;
      final hw = cw * 0.26;
      final r = Rect.fromLTRB(xo - hw, top + ch * 0.10, xo + hw, top + ch * 0.62);
      canvas.drawArc(r, sx < 0 ? math.pi / 2 : -math.pi / 2, math.pi, false, p);
    }
    final sw = w * 0.05, stemTop = top + ch, stemBot = stemTop + h * 0.05;
    canvas.drawPath(Path()..moveTo(cx - sw / 2, stemTop)..lineTo(cx + sw / 2, stemTop)..lineTo(cx + sw * 0.9, stemBot)..lineTo(cx - sw * 0.9, stemBot)..close(), p);
    canvas.drawRect(Rect.fromLTRB(cx - cw * 0.30, stemBot, cx + cw * 0.30, stemBot + h * 0.016), p);
    canvas.drawRect(Rect.fromLTRB(cx - cw * 0.42, stemBot + h * 0.016, cx + cw * 0.42, stemBot + h * 0.038), p);
    // звезда — сплошное отверстие
    final star = Path();
    final sr = cw * 0.11, scy = top + ch * 0.38;
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final rr = i.isEven ? sr : sr * 0.42;
      final pt = Offset(cx + rr * math.cos(a), scy + rr * math.sin(a));
      i == 0 ? star.moveTo(pt.dx, pt.dy) : star.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(star..close(), _hole);
  }

  /// Пьедестал 2–1–3: три ступени-контура внизу.
  void _podium(Canvas canvas, Size s, double slit) {
    final w = s.width, h = s.height;
    final p = _slit(slit);
    final bw = w * 0.24, base = h * 0.985;
    for (final (hh, off) in [(0.16, -1.0), (0.22, 0.0), (0.12, 1.0)]) {
      final x0 = w / 2 + off * bw - bw / 2 + off * w * 0.012;
      canvas.drawRect(Rect.fromLTRB(x0, base - h * hh, x0 + bw, base), p);
    }
  }

  @override
  bool shouldRepaint(WallpaperPainter old) => old.kind != kind || old.brightness != brightness || old.style != style && _differs(old.style, style);

  static bool _differs(WallpaperStyle a, WallpaperStyle b) =>
      a.front != b.front ||
      a.backDark != b.backDark ||
      a.backGlow != b.backGlow ||
      a.frontOpacity != b.frontOpacity ||
      a.vignette != b.vignette ||
      a.blur != b.blur ||
      a.eraseShape != b.eraseShape ||
      a.eraseSoft != b.eraseSoft ||
      a.eraseStrength != b.eraseStrength ||
      a.eraseSize != b.eraseSize;
}
