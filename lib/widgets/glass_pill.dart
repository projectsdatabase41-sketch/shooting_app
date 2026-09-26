import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Полупрозрачная «таблетка» с размытием того, что под ней (шапка и поле
/// ввода переписки). Скругление — половина высоты.
class GlassPill extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  /// null — половина высоты (таблетка). Поле ввода задаёт постоянный
  /// радиус, чтобы при многострочном тексте скругление не раздувалось.
  final double? radius;

  const GlassPill(
      {super.key, required this.child, this.padding = EdgeInsets.zero, this.onTap, this.color, this.radius});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? 999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: color ?? cs.surface.withValues(alpha: 0.55),
          shape: radius == null
              ? StadiumBorder(side: BorderSide(color: cs.onSurface.withValues(alpha: 0.08)))
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius!),
                  side: BorderSide(color: cs.onSurface.withValues(alpha: 0.08))),
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Круглая стеклянная кнопка (48×48) — «назад», меню, действия шапки.
class GlassCircleButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final Color? color;
  const GlassCircleButton({super.key, required this.icon, this.onTap, this.tooltip, this.size = 48, this.color});

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: GlassPill(onTap: onTap, color: color, child: Center(child: icon)),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Иконка чуть жирнее обычной: поверх заливки — обводка того же цвета
/// (шрифт Material Icons не переменный, `weight` на него не действует).
class BoldIcon extends StatelessWidget {
  final IconData icon;
  final double stroke;
  const BoldIcon(this.icon, {super.key, this.stroke = 0.25});

  @override
  Widget build(BuildContext context) {
    final style = IconTheme.of(context);
    final size = style.size ?? 24;
    final color = style.color ?? Theme.of(context).colorScheme.onSurface;
    final glyph = String.fromCharCode(icon.codePoint);
    TextStyle text(Paint? p) => TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          height: 1,
          color: p == null ? color : null,
          foreground: p,
        );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(glyph, style: text(null)),
          Text(glyph,
              style: text(Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = stroke
                ..color = color)),
        ],
      ),
    );
  }
}

/// Шапка экрана чата в стиле Telegram: не полоса, а отдельные стеклянные
/// плитки поверх содержимого (экран — `extendBodyBehindAppBar: true`).
class GlassHeader extends StatelessWidget implements PreferredSizeWidget {
  /// По умолчанию — «назад» (слегка жирная стрелка).
  final Widget? leading;
  final Widget title;
  final VoidCallback? onTitleTap;
  final List<Widget> actions;
  final EdgeInsetsGeometry titlePadding;

  const GlassHeader({
    super.key,
    this.leading,
    required this.title,
    this.onTitleTap,
    this.actions = const [],
    this.titlePadding = const EdgeInsets.symmetric(horizontal: 18),
  });

  static const double height = 60;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            if (leading != null || ModalRoute.of(context)?.canPop == true) ...[
              leading ??
                  GlassCircleButton(
                    icon: const BoldIcon(Icons.arrow_back),
                    tooltip: 'Назад',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: SizedBox(
                height: 48,
                child: GlassPill(
                  onTap: onTitleTap,
                  padding: titlePadding,
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
              ),
            ),
            for (final a in actions) ...[const SizedBox(width: 8), a],
          ],
        ),
      ),
    );
  }
}

/// Мягкое затемнение краёв ленты под стеклянной шапкой и полем ввода —
/// содержимое уходит под них плавно, а не обрывается. Класть в Stack
/// поверх ленты (Positioned.fill), касаний не перехватывает.
class EdgeShade extends StatelessWidget {
  final double top;
  final double bottom;
  const EdgeShade({super.key, this.top = 0, this.bottom = 0});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shade = Colors.black.withValues(alpha: dark ? 0.55 : 0.28);
    Widget band(double h, Alignment from) => Container(
          height: h,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: from,
              end: -from,
              colors: [shade, shade.withValues(alpha: 0)],
            ),
          ),
        );
    return IgnorePointer(
      child: Column(
        children: [
          if (top > 0) band(top, Alignment.topCenter),
          const Spacer(),
          if (bottom > 0) band(bottom, Alignment.bottomCenter),
        ],
      ),
    );
  }
}
