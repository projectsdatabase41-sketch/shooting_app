import '../services/economy_mode.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// «Стекло» для всех элементов, когда плитки главного экрана прозрачные (`TileStyle`):
/// кнопки и всплывающие окна тоже полупрозрачные и размывают то, что под ними.
/// Окна — чуть мутнее плиток (сильнее размытие и плотнее заливка).
class GlassTheme {
  GlassTheme._();

  static bool enabled = false;

  /// Множитель прозрачности (тот же ползунок, что у плиток): 0.2 — почти прозрачно … 2 — плотнее.
  static double alpha = 1.0;

  /// Растёт при изменении — тема приложения пересобирается.
  static final revision = ValueNotifier<int>(0);

  static void sync(bool glass, double a) {
    if (enabled == glass && alpha == a) return;
    enabled = glass;
    alpha = a;
    revision.value++;
  }

  /// Непрозрачность заливки кнопок.
  static double get buttonAlpha => (0.45 * alpha).clamp(0.12, 0.92).toDouble();

  /// Непрозрачность окон: плотнее кнопок — текст читается.
  static double get windowAlpha => (0.70 + (alpha - 1) * 0.15).clamp(0.45, 0.92).toDouble();

  static const double buttonBlur = 12;
  static const double windowBlur = 18;
}

/// Фон «стекло»: размытие под виджетом + полупрозрачная заливка + тонкая светлая кромка.
class GlassFill extends StatelessWidget {
  final Color color;
  final double radius;
  final double blur;
  final Widget? child;
  const GlassFill({super.key, required this.color, this.radius = 12, this.blur = GlassTheme.buttonBlur, this.child});

  @override
  Widget build(BuildContext context) {
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: child,
    );
    // blur <= 0 — без размытия подложки: у кнопок в прокручиваемом списке размытие «мигало» светлыми
    // пятнами проезжающего под ними содержимого.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blur <= 0 || EconomyMode.on ? box : BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: box),
    );
  }
}

/// Размытие того, что за всплывающим окном (только в режиме «стекло»).
class GlassBlur extends StatelessWidget {
  final Widget child;
  final double? radius;
  const GlassBlur({super.key, required this.child, this.radius});

  @override
  Widget build(BuildContext context) {
    if (!GlassTheme.enabled || EconomyMode.on) return child;
    Widget blurred = BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: GlassTheme.windowBlur, sigmaY: GlassTheme.windowBlur), child: child);
    if (radius != null) blurred = ClipRRect(borderRadius: BorderRadius.vertical(top: Radius.circular(radius!)), child: blurred);
    return blurred;
  }
}
