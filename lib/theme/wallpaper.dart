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

  /// Пока картинка не декодирована — ничего (виден обычный фон экрана), потом плавное появление.
  static Widget _frame(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) =>
      AnimatedOpacity(opacity: (wasSynchronouslyLoaded || frame != null) ? 1 : 0, duration: const Duration(milliseconds: 600), curve: Curves.easeOut, child: child);

  /// Ширина декодирования: по ширине экрана в пикселях (без лишней памяти и ресайза на лету).
  static int cacheWidthFor(BuildContext context) {
    final mq = MediaQuery.of(context);
    return (mq.size.width * mq.devicePixelRatio).round().clamp(360, 1440);
  }

  /// Кладёт в кэш картинки главного экрана заранее - первый показ без декодирования.
  static Future<void> warmUp(BuildContext context) async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final w = cacheWidthFor(context);
    for (final k in const ['home', 'settings']) {
      final name = 'assets/wall/${k}_${dark ? 'dark' : 'light'}';
      for (final suffix in const ['.jpg', '_b.jpg']) {
        if (!context.mounted) return;
        await precacheImage(ResizeImage(AssetImage('$name$suffix'), width: w), context).catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = 'assets/wall/${kind}_${dark ? 'dark' : 'light'}';
    final cw = cacheWidthFor(context);
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
          // Подложка среднего тона обоев лежит ВНУТРИ тех же фильтров (маска, яркость, контраст),
          // поэтому пока картинка проявляется, цвет страницы уже тот же и вспышки нет.
          Widget stack = Stack(fit: StackFit.expand, children: [
            ColoredBox(color: dark ? const Color(0xFF2C2C2C) : const Color(0xFFE4E4E4)),
            Image.asset('$name.jpg', fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, cacheWidth: cw, frameBuilder: _frame),
            if (blur > 0.01)
              Opacity(opacity: blur, child: Image.asset('${name}_b.jpg', fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, cacheWidth: cw, frameBuilder: _frame)),
          ]);
          if (BackdropTint.wBright != 0 || BackdropTint.wContrast != 1) {
            stack = ColorFiltered(colorFilter: ColorFilter.matrix(BackdropTint.wallpaperMatrix()), child: stack);
          }
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
