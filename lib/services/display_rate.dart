import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'local_db_service.dart';

/// Адаптивная частота обновления экрана (только Android): ~60 Гц в
/// мессенджере, статистике и настройках, максимум дисплея — на экране
/// мишени во время работы (решение пользователя, пункт 16 списка правок —
/// экономия заряда). Остальные платформы и устройства без выбора
/// режимов — молча ничего не делают.
class DisplayRate {
  static const String _key = 'adaptive_fps';

  static bool isEnabled(LocalDbService db) {
    final rows =
        db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key]);
    return rows.isEmpty || rows.first['hex'] != '0';
  }

  static void setEnabled(LocalDbService db, bool v) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [_key, v ? '1' : '0'],
    );
    if (!v) _apply(high: true); // выключили — вернуть максимум
  }

  /// `true` — режим с максимальной частотой (тренировка), `false` —
  /// экономный (~60 Гц, но не ниже 55, чтобы прокрутка не дёргалась).
  static Future<void> setActive(LocalDbService db, bool active) async {
    if (!isEnabled(db)) return;
    await _apply(high: active);
  }

  static Future<void> _apply({required bool high}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final modes = await FlutterDisplayMode.supported;
      final current = await FlutterDisplayMode.active;
      final same = modes
          .where((m) => m.width == current.width && m.height == current.height)
          .toList();
      if (same.length < 2) return;
      same.sort((a, b) => a.refreshRate.compareTo(b.refreshRate));
      final target = high
          ? same.last
          : same.firstWhere((m) => m.refreshRate >= 55,
              orElse: () => same.last);
      if (target != current) await FlutterDisplayMode.setPreferredMode(target);
    } catch (_) {
      // нет плагина/режимов — не критично
    }
  }
}
