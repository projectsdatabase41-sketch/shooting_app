import 'package:flutter/services.dart';

/// Запрет скриншотов/превью в «недавних» для личных экранов.
///
/// Android: FLAG_SECURE на окне (канал `nexus/secure`). На остальных
/// платформах — тихо ничего не делает.
///
/// Счётчик: экраны могут накладываться (переписка поверх списка чатов),
/// поэтому флаг снимается только когда закрыт последний такой экран.
class SecureScreen {
  SecureScreen._();

  static const _channel = MethodChannel('nexus/secure');
  static int _depth = 0;

  static Future<void> enable() async {
    _depth++;
    if (_depth != 1) return;
    try {
      await _channel.invokeMethod('setSecure', {'on': true});
    } catch (_) {
      // Не Android/канал недоступен — просто без защиты от скриншотов.
    }
  }

  static Future<void> disable() async {
    if (_depth == 0) return;
    _depth--;
    if (_depth != 0) return;
    try {
      await _channel.invokeMethod('setSecure', {'on': false});
    } catch (_) {}
  }
}
