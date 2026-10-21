import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';


/// Рисовальщик слоёв обоев (только для генератора tool/gen_wallpapers_test.dart): два листа бумаги -
/// передний с прорезями и задний со свечением. В приложении не используется: там готовые картинки.
class WallpaperStyle {
  final Color front;
  final Color backDark;
  final Color backGlow;
  final double frontOpacity;
  final double vignette;
  final double blur;
  const WallpaperStyle({
    required this.front,
    required this.backDark,
    required this.backGlow,
    required this.frontOpacity,
    required this.vignette,
    required this.blur,
  });
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

    // Размытие — всех обоев целиком (прорези становятся мягкими); масштабируется с шириной экрана.
    final sigma = style.blur * (w / 400);
    if (sigma > 0.3) {
      canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp));
    } else {
      canvas.save();
    }

    // 1. Задний лист (виден только в прорезях): градиент со свечением.
    canvas.drawRect(rect, Paint()..color = style.backDark);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(glow, math.max(w, h) * 0.95, [style.backGlow, style.backGlow.withValues(alpha: 0)], [0.0, 1.0]),
    );

    // 2. Передний лист с вырезами: вырезы стираются режимом clear внутри отдельного слоя.
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, Paint()..color = style.front.withValues(alpha: style.frontOpacity));
    _cutouts(canvas, size);
    // Виньетка переднего листа: к центру лист истончается (проглядывает задний), к краям остаётся плотным.
    if (style.vignette > 0.01) {
      canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..shader = ui.Gradient.radial(
            glow,
            math.max(w, h) * 0.85,
            [Colors.black.withValues(alpha: 0.85 * style.vignette), Colors.black.withValues(alpha: 0)],
            [0.0, 1.0],
          ),
      );
    }
    canvas.restore();

    canvas.restore(); // конец размытия
  }

  Offset _glowCenter(Size s) => switch (kind) {
        'settings' => Offset(s.width / 2, 0),
        'ai' => Offset(s.width / 2, s.height * 0.22),
        'champions' => Offset(s.width / 2, s.height * 0.36),
        'finals' => Offset(s.width / 2, s.height * 0.24),
        'messenger' => Offset(s.width * 0.7, s.height * 0.25),
        _ => Offset(s.width / 2, s.height * 0.40),
      };

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
    final slit = math.max(1.1, w * 0.0021);
    switch (kind) {
      case 'settings':
        _rings(canvas, Offset(w / 2, 0), s, List.generate(10, (i) => i + 2), slit);
        _icons(canvas, s, slit, 7);
      case 'ai':
        _rings(canvas, Offset(w / 2, h * 0.22), s, List.generate(7, (i) => i + 1), slit * 1.2);
        _icons(canvas, s, slit, 11);
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

  static const _tileIcons = [
    Icons.gps_fixed,
    Icons.bar_chart,
    Icons.menu_book,
    Icons.chat_bubble_outline,
    Icons.smart_toy_outlined,
    Icons.settings_outlined,
    Icons.emoji_events_outlined,
    Icons.timer_outlined,
  ];

  /// Прорези в виде значков кнопок главного экрана: контуры глифов, редкая сетка с разбросом и поворотом.
  void _icons(Canvas canvas, Size s, double slit, int seed) {
    final cell = s.width * 0.34;
    final rnd = math.Random(seed);
    for (var row = 0; row < s.height / cell + 1; row++) {
      for (var c = 0; c < s.width / cell + 1; c++) {
        final icon = _tileIcons[rnd.nextInt(_tileIcons.length)];
        final size = cell * (0.38 + rnd.nextDouble() * 0.2);
        final pos = Offset((c + 0.5 + (row.isOdd ? 0.5 : 0) + (rnd.nextDouble() - 0.5) * 0.3) * cell, (row + 0.5 + (rnd.nextDouble() - 0.5) * 0.3) * cell);
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              fontSize: size,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = math.max(1.0, slit * 0.8)
                ..blendMode = BlendMode.clear,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(pos.dx, pos.dy);
        canvas.rotate((rnd.nextDouble() - 0.5) * 0.5);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      }
    }
  }

  /// Узор мессенджера: мишени, прицелы, ромбы и кольца в шахматном порядке.
  void _pattern(Canvas canvas, Size s, double slit) {
    final cell = s.width * 0.15;
    final u = cell * 0.17;
    final p = _slit(math.max(1.0, slit * 0.8));
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
  bool shouldRepaint(WallpaperPainter old) => true;
}
