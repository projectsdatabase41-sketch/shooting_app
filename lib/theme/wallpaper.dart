import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'backdrop_tint.dart';

/// Обои экрана [kind]: home | messenger | settings | ai | champions | finals.
///
/// Это готовые чёрно-белые картинки (тёмная и светлая тема; генератор - tool/gen_wallpapers_test.dart),
/// поверх которых лежит цветная «маска-стекло»: цвет, прозрачность и размытие настраиваются.
/// Размытие - это плавное подмешивание заранее размытой копии (дёшево, без фильтров на лету).
class Wallpaper extends StatelessWidget {
  final String kind;
  const Wallpaper({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = 'assets/wall/${kind}_${dark ? 'dark' : 'light'}';
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: BackdropTint.revision,
        builder: (_, __, ___) {
          final custom = BackdropTint.customImage;
          if (BackdropTint.customOn && custom != null) {
            return CustomPaint(painter: _CustomWallpaperPainter(custom, BackdropTint.customMatrix(), BackdropTint.cVignette), size: Size.infinite);
          }
          final blur = (BackdropTint.blur / 30).clamp(0.0, 1.0).toDouble();
          final mask = BackdropTint.maskColor(kind);
          Widget stack = Stack(fit: StackFit.expand, children: [
            Image.asset('$name.jpg', fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
            if (blur > 0.01)
              Opacity(opacity: blur, child: Image.asset('${name}_b.jpg', fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium)),
          ]);
          if (mask != null) stack = ColorFiltered(colorFilter: ColorFilter.mode(mask, BlendMode.color), child: stack);
          return stack;
        },
      ),
    );
  }
}

/// Свои обои: фото по размеру экрана (cover) с яркостью, контрастом, оттенком и виньеткой.
class _CustomWallpaperPainter extends CustomPainter {
  final ui.Image image;
  final List<double> matrix;
  final double vignette;
  _CustomWallpaperPainter(this.image, this.matrix, this.vignette);

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final scale = math.max(size.width / src.width, size.height / src.height);
    final dw = src.width * scale, dh = src.height * scale;
    final dst = Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
    canvas.drawImageRect(image, src, dst, Paint()..colorFilter = ColorFilter.matrix(matrix)..filterQuality = FilterQuality.medium);
    if (vignette > 0.01) {
      final rect = Offset.zero & size;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            rect.center,
            math.max(size.width, size.height) * 0.75,
            [Colors.transparent, Colors.black.withValues(alpha: 0.8 * vignette)],
            [0.5, 1.0],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_CustomWallpaperPainter old) => old.image != image || old.vignette != vignette || old.matrix.toString() != matrix.toString();
}
