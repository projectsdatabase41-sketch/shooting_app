import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import '../models/color_presets.dart';
import '../models/target_color_scheme.dart';
import '../services/ai_settings.dart';
import 'workspace_view_model.dart';
import '../services/local_db_service.dart';

/// Персонализация цвета (часть A логики-спека). Грузит `color_prefs` при
/// старте, отдаёт готовый `TargetColorScheme`. Если строки для ключа нет
/// (первый запуск, или добавлен новый элемент в будущей версии) —
/// берётся дефолт из кода, в базу ничего не пишется, пока пользователь
/// не изменит значение сам (A.2).
class PersonalizationViewModel extends ChangeNotifier {
  final LocalDbService db;

  PersonalizationViewModel(this.db);

  TargetColorScheme _scheme = TargetColorScheme.defaultScheme;
  TargetColorScheme get scheme => _scheme;

  /// "Недавние цвета" — последние N (6) уникальных HEX, ephemeral в
  /// рамках сессии редактирования, НЕ персистентно между запусками
  /// (A.3.1) — хранить в БД избыточно.
  final List<Color> _recentColors = [];
  List<Color> get recentColors => List.unmodifiable(_recentColors);

  static const int _maxRecentColors = 6;

  /// Светлая/тёмная тема ИНТЕРФЕЙСА (не мишени — см. комментарий к
  /// `AppTheme`). Хранится в той же таблице `color_prefs`, что и цвета:
  /// это простое key-value хранилище, отдельная таблица ради одной
  /// строки избыточна. Значение кладётся в колонку `hex` строкой
  /// 'system'/'light'/'dark' — там уже так хранится булев
  /// `shot_number_text_auto` ('1'/'0'), так что прецедент есть.
  static const String themeModeKey = 'app_theme_mode';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [themeModeKey, mode.name],
    );
    notifyListeners();
  }

  static ThemeMode _themeModeFromString(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  void loadFromDb() {
    final rows = db.db.select('SELECT key, hex FROM color_prefs');
    var s = TargetColorScheme.defaultScheme;
    for (final row in rows) {
      final key = row['key'] as String;
      final hex = row['hex'] as String;
      if (!TargetColorScheme.allKeys.contains(key)) continue;
      if (!TargetColorScheme.isValidHex(hex)) continue;
      s = s.copyWithKey(key, TargetColorScheme.hexToColor(hex));
    }
    final autoRow = db.db.select(
      "SELECT hex FROM color_prefs WHERE key = 'shot_number_text_auto'",
    );
    final auto = autoRow.isEmpty ? true : autoRow.first['hex'] == '1';
    _scheme = s.copyWith(shotNumberTextAuto: auto);

    final themeRow = db.db.select(
      'SELECT hex FROM color_prefs WHERE key = ?',
      [themeModeKey],
    );
    _themeMode = _themeModeFromString(themeRow.isEmpty ? null : themeRow.first['hex'] as String?);

    notifyListeners();
  }

  void _persistKey(String key, Color value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, TargetColorScheme.colorToHex(value)],
    );
  }

  void setColor(String key, Color value) {
    _scheme = _scheme.copyWithKey(key, value);
    _persistKey(key, value);
    _pushRecent(value);
    notifyListeners();
  }

  void setShotNumberTextAuto(bool auto) {
    _scheme = _scheme.copyWith(shotNumberTextAuto: auto);
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      ['shot_number_text_auto', auto ? '1' : '0'],
    );
    notifyListeners();
  }

  void _pushRecent(Color value) {
    _recentColors.removeWhere((c) => c.toARGB32() == value.toARGB32());
    _recentColors.insert(0, value);
    if (_recentColors.length > _maxRecentColors) {
      _recentColors.removeRange(_maxRecentColors, _recentColors.length);
    }
  }

  /// Сброс одной строки к дефолту — вызывается ПОСЛЕ подтверждения
  /// диалогом на уровне UI (A.3: сброс необратим, поэтому подтверждение
  /// обязательно там, не здесь).
  void resetKey(String key) {
    final def = _scheme.defaultFor(key);
    _scheme = _scheme.copyWithKey(key, def);
    db.db.execute('DELETE FROM color_prefs WHERE key = ?', [key]);
    notifyListeners();
  }

  /// "Сбросить все цвета" — вызывается ПОСЛЕ подтверждения (A.3).
  ///
  /// Чистит только цветовые строки: раньше здесь было `DELETE FROM
  /// color_prefs` без условия, и сброс цветов мишени заодно сбрасывал бы
  /// выбранную тему интерфейса — не то, о чём пользователь просит,
  /// нажимая "сбросить все цвета".
  void resetAll() {
    _scheme = TargetColorScheme.defaultScheme;
    // Чистим ТОЛЬКО цветовые строки. В той же key-value таблице лежат
    // тема интерфейса и настройки ИИ (ключ, модели, адрес книг) — снести
    // их вместе с цветами было бы неожиданностью для того, кто нажал
    // "сбросить все цвета".
    final protected = [themeModeKey, ...AiSettings.allKeys, ...WorkspaceViewModel.allKeys];
    final placeholders = List.filled(protected.length, '?').join(', ');
    db.db.execute('DELETE FROM color_prefs WHERE key NOT IN ($placeholders)', protected);
    notifyListeners();
  }

  /// Применение пресета — ОДНА транзакция, `notifyListeners()` вызывается
  /// один раз, не 15 раз подряд (A.2.1 — иначе заметное мерцание).
  void applyPreset(ColorPreset preset) {
    db.db.execute('BEGIN');
    try {
      for (final key in TargetColorScheme.allKeys) {
        _persistKey(key, preset.scheme[key]);
      }
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    _scheme = preset.scheme.copyWith(shotNumberTextAuto: _scheme.shotNumberTextAuto);
    notifyListeners();
  }

  ColorPreset? get activePreset => ColorPresets.activeFor(_scheme);

  /// Импорт — all-or-nothing (A.2.2), одна транзакция как и пресет.
  void importJson(String json) {
    final imported = ColorSchemeIo.importFromJson(json, _scheme); // может бросить FormatException
    db.db.execute('BEGIN');
    try {
      for (final key in TargetColorScheme.allKeys) {
        _persistKey(key, imported[key]);
      }
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    _scheme = imported;
    notifyListeners();
  }

  String exportJson() => ColorSchemeIo.exportToJson(_scheme);
}
