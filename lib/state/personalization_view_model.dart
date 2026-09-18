import 'dart:ui' show Color, Locale;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import '../models/app_color_presets.dart';
import '../models/color_presets.dart';
import '../models/target_color_scheme.dart';
import '../services/ai_settings.dart';
import 'home_tabs_view_model.dart';
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

  /// "Режим разработчика" (решение пользователя) — открывает недоделанные
  /// вкладки (сейчас: Мессенджер, Задания тренера), которые иначе не
  /// показываются обычным пользователям. Пароль не про защиту от
  /// взлома — приложение и так не умеет прятать секреты от того, кто
  /// откроет исходники или собранный код — а про то, чтобы случайный
  /// человек не наткнулся на сырую функцию. Включается скрытым жестом
  /// в настройках (7 нажатий на заголовок экрана), не отдельным пунктом
  /// меню — иначе сам факт его существования был бы на виду у всех.
  static const String devModeKey = 'dev_mode_enabled';
  static const String devModePassword = '9612';

  bool _devMode = false;
  bool get devMode => _devMode;

  bool tryEnableDevMode(String password) {
    if (password != devModePassword) return false;
    _devMode = true;
    _persistDevMode();
    notifyListeners();
    return true;
  }

  void disableDevMode() {
    _devMode = false;
    _persistDevMode();
    notifyListeners();
  }

  void _persistDevMode() {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [devModeKey, _devMode ? '1' : '0'],
    );
  }

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

  /// Язык приложения — по умолчанию системный (пункт списка правок).
  ///
  /// ЧЕСТНОЕ ОГРАНИЧЕНИЕ: в приложении нет инфраструктуры перевода (ARB,
  /// `GlobalMaterialLocalizations.delegates`/`supportedLocales`) — весь
  /// текст сейчас захардкожен по-русски прямо в виджетах. Эта настройка
  /// хранит выбор и передаёт его в `MaterialApp.locale`, что переводит
  /// системные виджеты (даты/числа через `intl`, стандартные подписи
  /// Material), но НЕ переводит сам текст экранов — для этого понадобится
  /// отдельная большая работа (вынести все строки в ARB-файлы).
  static const String localeKey = 'app_locale';

  /// `null` — системный язык устройства.
  String? _localeCode;
  String? get localeCode => _localeCode;
  Locale? get locale => _localeCode == null ? null : Locale(_localeCode!);

  void setLocaleCode(String? code) {
    if (code == _localeCode) return;
    _localeCode = code;
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [localeKey, code ?? 'system'],
    );
    notifyListeners();
  }

  // ---- Цвета ПРИЛОЖЕНИЯ (не мишени) — фон экранов, кнопки, текст на
  // кнопках (решение пользователя: "в настройках цвета мало"). `null` —
  // цвет темы по умолчанию (`AppTheme`), не тронут пользователем.
  // Намеренно НЕ часть `TargetColorScheme` — см. комментарий в
  // `AppTheme` о том, почему цвета мишени и цвета интерфейса не связаны.
  static const String appBackgroundKey = 'app_bg_color';
  static const String appButtonKey = 'app_button_color';
  static const String appButtonTextKey = 'app_button_text_color';
  static const List<String> appColorKeys = [appBackgroundKey, appButtonKey, appButtonTextKey];

  Color? _appBackgroundColor;
  Color? _appButtonColor;
  Color? _appButtonTextColor;
  Color? get appBackgroundColor => _appBackgroundColor;
  Color? get appButtonColor => _appButtonColor;
  Color? get appButtonTextColor => _appButtonTextColor;

  void setAppBackgroundColor(Color? c) => _setAppColor(appBackgroundKey, c, (v) => _appBackgroundColor = v);
  void setAppButtonColor(Color? c) => _setAppColor(appButtonKey, c, (v) => _appButtonColor = v);
  void setAppButtonTextColor(Color? c) => _setAppColor(appButtonTextKey, c, (v) => _appButtonTextColor = v);

  void _setAppColor(String key, Color? c, void Function(Color?) assign) {
    assign(c);
    if (c == null) {
      db.db.execute('DELETE FROM color_prefs WHERE key = ?', [key]);
    } else {
      _persistKey(key, c);
      _pushRecent(c);
    }
    notifyListeners();
  }

  /// Готовый набор из трёх цветов приложения разом — "пресеты для меню"
  /// (решение пользователя), тот же приём, что `applyPreset` у мишени.
  void applyAppColorPreset(AppColorPreset preset) {
    _appBackgroundColor = preset.background;
    _appButtonColor = preset.button;
    _appButtonTextColor = preset.buttonText;
    _persistKey(appBackgroundKey, preset.background);
    _persistKey(appButtonKey, preset.button);
    _persistKey(appButtonTextKey, preset.buttonText);
    notifyListeners();
  }

  bool get hasCustomAppColors => _appBackgroundColor != null || _appButtonColor != null || _appButtonTextColor != null;

  void resetAppColors() {
    _appBackgroundColor = null;
    _appButtonColor = null;
    _appButtonTextColor = null;
    db.db.execute('DELETE FROM color_prefs WHERE key IN (?, ?, ?)', appColorKeys);
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

    final localeRow = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [localeKey]);
    final localeValue = localeRow.isEmpty ? 'system' : localeRow.first['hex'] as String;
    _localeCode = localeValue == 'system' ? null : localeValue;

    Color? readAppColor(String key) {
      final row = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
      if (row.isEmpty) return null;
      final hex = row.first['hex'] as String?;
      return (hex == null || !TargetColorScheme.isValidHex(hex)) ? null : TargetColorScheme.hexToColor(hex);
    }

    _appBackgroundColor = readAppColor(appBackgroundKey);
    _appButtonColor = readAppColor(appButtonKey);
    _appButtonTextColor = readAppColor(appButtonTextKey);

    final devModeRow = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [devModeKey]);
    _devMode = devModeRow.isNotEmpty && devModeRow.first['hex'] == '1';

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
    final protected = [
      themeModeKey,
      localeKey,
      devModeKey,
      ...AiSettings.allKeys,
      ...WorkspaceViewModel.allKeys,
      ...HomeTabsViewModel.allKeys,
      ...appColorKeys,
    ];
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
