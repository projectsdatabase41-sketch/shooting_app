import 'package:web/web.dart' as web;

/// Мобильный браузер: iPhone/iPad, Android-телефон, мобильный UA или
/// небольшой экран с тачскрином (планшет). Всё остальное — веб с компьютера.
bool get isMobileBrowser {
  final ua = web.window.navigator.userAgent.toLowerCase();
  final mobileUa = RegExp(r'iphone|ipod|ipad|android|windows phone|mobile|opera mini')
      .hasMatch(ua);
  if (mobileUa) return true;
  final touch = web.window.navigator.maxTouchPoints;
  final width = web.window.screen.width;
  // iPad в современных версиях притворяется Macintosh — ловим по тачскрину.
  return touch > 1 && width <= 1024;
}
