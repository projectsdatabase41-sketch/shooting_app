import '../theme/wallpaper.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:flutter/material.dart';

/// Фоновая картинка экрана (минимализм: кольца мишени на спокойном фоне),
/// тёмная/светлая по теме. Веб — 1080×1920, Android — 1440×2560.
/// [kind]: home | messenger | settings | ai | champions (см. tools/gen_backgrounds.py).
class AppBackdrop extends StatefulWidget {
  final String kind;
  final Widget child;
  const AppBackdrop({super.key, required this.kind, required this.child});

  static String path(String kind, Brightness b) =>
      'assets/bg/${kIsWeb ? 'web' : 'android'}/${kind}_${b == Brightness.dark ? 'dark' : 'light'}.webp';

  /// Какой фон сейчас у верхнего экрана — по нему на широком окне закрашиваются боковые поля,
  /// чтобы они продолжали картинку экрана без шва.
  static final active = ValueNotifier<String>('home');
  static final List<_AppBackdropState> _stack = [];

  @override
  State<AppBackdrop> createState() => _AppBackdropState();
}

class _AppBackdropState extends State<AppBackdrop> {
  @override
  void initState() {
    super.initState();
    AppBackdrop._stack.add(this);
    _publish();
  }

  @override
  void didUpdateWidget(AppBackdrop old) {
    super.didUpdateWidget(old);
    if (old.kind != widget.kind) _publish();
  }

  @override
  void dispose() {
    AppBackdrop._stack.remove(this);
    final last = AppBackdrop._stack.isEmpty ? 'home' : AppBackdrop._stack.last.widget.kind;
    WidgetsBinding.instance.addPostFrameCallback((_) => AppBackdrop.active.value = last);
    super.dispose();
  }

  void _publish() {
    final kind = widget.kind;
    // Не во время построения: уведомление подписчиков — после кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AppBackdrop._stack.isNotEmpty && AppBackdrop._stack.last == this) AppBackdrop.active.value = kind;
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return Stack(fit: StackFit.expand, children: [
      // Обои — слои (см. theme/wallpaper.dart): рисуются по размеру всего окна и по центру,
      // чтобы бесшовно продолжаться на боковых полях широкого экрана (main.dart).
      OverflowBox(
        minWidth: w,
        maxWidth: w,
        child: SizedBox(width: w, child: Wallpaper(kind: widget.kind)),
      ),
      widget.child,
    ]);
  }
}
