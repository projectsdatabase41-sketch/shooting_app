import 'package:web/web.dart' as web;

/// Запасное копирование на вебе: браузер запретил Clipboard API (нет фокуса
/// на странице или нет разрешения) — копируем через скрытый textarea и
/// `document.execCommand('copy')`, который работает внутри обработчика жеста.
bool copyFallback(String text) {
  final area = web.HTMLTextAreaElement()
    ..value = text
    ..readOnly = true
    ..style.position = 'fixed'
    ..style.opacity = '0'
    ..style.top = '0'
    ..style.left = '0';
  web.document.body?.append(area);
  try {
    area.select();
    area.setSelectionRange(0, text.length);
    final ok = web.document.execCommand('copy');
    return ok;
  } catch (_) {
    return false;
  } finally {
    area.remove();
  }
}
