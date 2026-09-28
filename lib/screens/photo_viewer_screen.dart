import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/glass_pill.dart';

/// Просмотр фото поверх открытого экрана: фото и зум — на весь экран,
/// позади — размытие и затемнение (тёмная тема) или белая дымка (светлая),
/// «назад» — круглая стеклянная кнопка, как в мессенджере.
class PhotoViewerScreen extends StatelessWidget {
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
            child: InteractiveViewer(
              maxScale: 6,
              clipBehavior: Clip.none,
              child: SizedBox.expand(child: Image(image: image, fit: BoxFit.contain)),
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
