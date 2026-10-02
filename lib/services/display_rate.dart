import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'local_db_service.dart';

/// Адаптивная частота обновления экрана (только Android): максимум
/// дисплея везде, где человек пользуется телефоном (анимации, прокрутка),
/// и ~60 Гц на открытой тренировке — стрелок почти не трогает экран, а он
/// включён часами (решение пользователя, пункт 16 списка правок —
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

  /// `true` — открыта тренировка: экономный режим (~60 Гц, но не ниже
  /// 55, чтобы не дёргалось), `false` — максимум дисплея.
  static Future<void> setTraining(LocalDbService db, bool training) async {
    if (!isEnabled(db)) return;
    await _apply(high: !training);
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
