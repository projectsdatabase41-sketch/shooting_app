import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/glass_pill.dart';

/// Просмотр фото поверх открытого экрана: фото и зум — на весь экран,
/// позади — размытие и затемнение (тёмная тема) или белая дымка (светлая),
/// «назад» — круглая стеклянная кнопка, как в мессенджере. Тап по фону
/// (вне самой картинки, в размытой области) закрывает просмотр.
class PhotoViewerScreen extends StatefulWidget {
  final ImageProvider image;
  const PhotoViewerScreen({super.key, required this.image});

  /// Открыть прозрачным маршрутом — чтобы под фото был виден прежний экран.
  static Future<void> open(BuildContext context, ImageProvider image) => Navigator.of(context).push(PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => PhotoViewerScreen(image: image),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ));

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  final _controller = TransformationController();
  Size? _imageSize;
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener((info, _) {
    if (mounted) {
      setState(() => _imageSize = Size(info.image.width.toDouble(), info.image.height.toDouble()));
    }
  });

  @override
  void initState() {
    super.initState();
    _stream = widget.image.resolve(ImageConfiguration.empty)..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _controller.dispose();
    super.dispose();
  }

  /// Тап вне прямоугольника картинки (с учётом зума/сдвига) — закрыть.
  void _onTap(TapUpDetails d, Size view) {
    final img = _imageSize;
    if (img == null) return;
    final scale = (view.width / img.width) < (view.height / img.height)
        ? view.width / img.width
        : view.height / img.height;
    final w = img.width * scale, h = img.height * scale;
    final rect = Rect.fromLTWH((view.width - w) / 2, (view.height - h) / 2, w, h);
    if (!rect.contains(_controller.toScene(d.localPosition))) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: ColoredBox(color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.5)),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onTap(d, c.biggest),
                child: InteractiveViewer(
                  transformationController: _controller,
                  maxScale: 6,
                  clipBehavior: Clip.none,
                  child: SizedBox.expand(child: Image(image: widget.image, fit: BoxFit.contain)),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: MediaQuery.paddingOf(context).top + 8,
            child: GlassCircleButton(
              icon: const BoldIcon(Icons.arrow_back),
              tooltip: tr('Назад'),
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}
