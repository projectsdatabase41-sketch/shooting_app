import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'copy_text_io.dart' if (dart.library.js_interop) 'copy_text_web.dart' as impl;

/// Копирование текста в буфер обмена с запасным путём для веба.
///
/// На вебе `Clipboard.setData` падает с `PlatformException(copy_fail)`, если
/// страница не в фокусе или браузер не дал разрешение (отзыв 16.11 16:25,
/// экран «Данные и синхронизация»). Тогда копируем через скрытый textarea и
/// `execCommand('copy')`. Исключений не бросает: возвращает false, если
/// скопировать не удалось, — вызывающий показывает это пользователю.
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    if (kIsWeb) {
      try {
        return impl.copyFallback(text);
      } catch (_) {}
    }
    return false;
  }
}
