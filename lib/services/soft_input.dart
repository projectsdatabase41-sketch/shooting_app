import 'package:flutter/services.dart';

/// Управление режимом мягкой клавиатуры (Android).
///
/// Зачем: в 3D-вьюере WebView перерисовывает сцену при каждом изменении
/// размера окна, а при открытии клавиатуры Android (adjustResize) меняет
/// размер окна — отсюда «зависание» и дёрганье (отзыв 26.11). На время
/// экрана вьюера включаем ADJUST_NOTHING, при уходе возвращаем как было.
class SoftInput {
  SoftInput._();

  static const _channel = MethodChannel('nexus/soft_input');

  static Future<void> adjustNothing() async {
    try {
      await _channel.invokeMethod('setMode', {'mode': 'nothing'});
    } catch (_) {
      // Не Android/канал недоступен — работаем как обычно.
    }
  }

  static Future<void> adjustResize() async {
    try {
      await _channel.invokeMethod('setMode', {'mode': 'resize'});
    } catch (_) {}
  }
}
