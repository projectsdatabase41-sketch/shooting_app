import 'package:flutter/foundation.dart';

import '../theme/app_transitions.dart';
import '../theme/glass.dart';

/// Режим «Эконом»: меньше нагрузки на телефон (iPhone и слабые Android) — без обоев, размытия стекла,
/// анимаций переходов и кадров-превью в кружках. Настройки внешнего вида не меняются: при выключении всё возвращается.
class EconomyMode {
  EconomyMode._();

  static const _key = 'economy_on';
  static bool on = false;

  /// Растёт при переключении: экраны с фоном перерисовываются.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void load(dynamic db) {
    try {
      final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key]);
      on = r.isNotEmpty && '${r.first['hex']}' == '1';
      if (on) AnimSettings.enabled = false;
    } catch (_) {}
  }

  static void set(dynamic db, bool value) {
    on = value;
    db.db.execute('INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [_key, value ? '1' : '0']);
    if (value) {
      AnimSettings.enabled = false;
    } else {
      AnimSettings.load(db); // вернуть выбранное пользователем
    }
    revision.value++;
    GlassTheme.revision.value++; // тема приложения пересобирается: кнопки сплошного цвета
  }
}
