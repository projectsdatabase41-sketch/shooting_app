import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Фоновая картинка экрана (минимализм: кольца мишени на спокойном фоне),
/// тёмная/светлая по теме. Веб — 1080×1920, Android — 1440×2560.
/// [kind]: home | messenger | settings | ai (см. tools/gen_backgrounds.py).
class AppBackdrop extends StatelessWidget {
  final String kind;
  final Widget child;
  const AppBackdrop({super.key, required this.kind, required this.child});

  static String path(String kind, Brightness b) =>
      'assets/bg/${kIsWeb ? 'web' : 'android'}/${kind}_${b == Brightness.dark ? 'dark' : 'light'}.webp';

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Stack(fit: StackFit.expand, children: [
      Image.asset(path(kind, b),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      child,
    ]);
  }
}
