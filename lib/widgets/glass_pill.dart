import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Полупрозрачная «таблетка» с размытием того, что под ней (шапка и поле
/// ввода переписки). Скругление — половина высоты.
class GlassPill extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  const GlassPill({super.key, required this.child, this.padding = EdgeInsets.zero, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: color ?? cs.surface.withValues(alpha: 0.55),
          shape: StadiumBorder(side: BorderSide(color: cs.onSurface.withValues(alpha: 0.08))),
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
