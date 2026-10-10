import 'package:flutter/foundation.dart';

import 'local_db_service.dart';

/// Необязательные модули приложения (решение пользователя: базовое — заметки
/// тренировок спортсмена и тренера; остальное включается в настройках и по
/// умолчанию спрятано).
enum AppModule {
  messenger('module_messenger'),
  assistant('module_assistant'),
  localAi('module_local_ai'),
  services('module_services'),
  finals('module_finals');

  final String key;
  const AppModule(this.key);
}

/// Включённость модулей. У тех, кто уже пользовался приложением до появления
/// настройки (есть сохранённые вкладки), всё остаётся включённым — вкладки не
/// должны внезапно пропасть; у новых установок модули выключены.
class ModulesSettings {
  ModulesSettings._();

  /// Меняется при каждом переключении — на него подписан главный экран.
  static final revision = ValueNotifier<int>(0);

  static const _initKey = 'modules_initialized';

  static String? _read(LocalDbService db, String key) {
    final rows =
        db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['hex'] as String?;
  }

  static void _write(LocalDbService db, String key, String value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, value],
    );
  }

  /// Один раз определяет начальные значения.
  static void ensureInitialized(LocalDbService db) {
    if (_read(db, _initKey) != null) return;
    final existingUser = _read(db, 'home_tabs_visible_athlete') != null ||
        _read(db, 'home_tabs_visible_coach') != null;
    for (final m in AppModule.values) {
      _write(db, m.key, existingUser ? '1' : '0');
    }
    _write(db, _initKey, '1');
  }

  static bool isOn(LocalDbService db, AppModule m) {
    ensureInitialized(db);
    return _read(db, m.key) == '1';
  }

  static void set(LocalDbService db, AppModule m, bool on) {
    ensureInitialized(db);
    _write(db, m.key, on ? '1' : '0');
    revision.value++;
  }
}
