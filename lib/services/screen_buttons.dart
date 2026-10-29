import 'package:flutter/foundation.dart';

import '../models/home_tab_specs.dart';
import 'local_db_service.dart';

/// «Кнопки на экране»: одна кнопка поверх всех страниц, из которой веером раскрываются быстрые действия
/// (отзывы, голосовое управление и разделы с рабочего стола). Хранится в `color_prefs`.
class ScreenButtons {
  ScreenButtons._();

  static const _kOn = 'screen_buttons_on';
  static const _kTabs = 'screen_buttons_tabs';
  static const _kLeft = 'screen_buttons_left';
  static const _kBottom = 'screen_buttons_bottom';

  /// Включено по умолчанию; пока выключено — отзывы и микрофон показываются отдельными кнопками, как раньше.
  static final ValueNotifier<bool> on = ValueNotifier(true);

  /// Разделы рабочего стола, добавленные в веер (по порядку).
  static final ValueNotifier<List<String>> tabs = ValueNotifier(const []);

  /// Разделы, недоступные сейчас (модуль выключен и т. п.) — ставит главный экран.
  static Set<String> suppressed = {};

  /// Открыть раздел рабочего стола поверх текущей страницы — ставит главный экран.
  static void Function(String id)? openTab;

  /// Действия, которые ставят оверлеи отзывов и голоса.
  static VoidCallback? openFeedback, voiceTap;

  static String _read(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? '' : '${r.first['hex']}';
  }

  static void _write(LocalDbService db, String key, String v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        [key, v],
      );

  /// Разделы, которые можно положить в веер ("Настройки" живут в шапке главного экрана).
  static List<String> get candidates => [for (final id in homeTabSpecs.keys) if (id != 'settings') id];

  /// Положение кнопки: слева ли, и высота над нижним краем.
  static final ValueNotifier<bool> left = ValueNotifier(false);
  static final ValueNotifier<double> bottom = ValueNotifier(120);

  static void setLeft(LocalDbService db, bool v) {
    _write(db, _kLeft, v ? '1' : '0');
    left.value = v;
  }

  static void setBottom(LocalDbService db, double v) {
    _write(db, _kBottom, v.round().toString());
    bottom.value = v.roundToDouble();
  }

  static void load(LocalDbService db) {
    on.value = _read(db, _kOn) != '0';
    tabs.value = parseTabs(_read(db, _kTabs));
    left.value = _read(db, _kLeft) == '1';
    bottom.value = (double.tryParse(_read(db, _kBottom)) ?? 120).clamp(60, 400).toDouble();
  }

  static List<String> parseTabs(String raw) =>
      [for (final id in raw.split(',')) if (homeTabSpecs.containsKey(id) && id != 'settings') id];

  static void setOn(LocalDbService db, bool v) {
    _write(db, _kOn, v ? '1' : '0');
    on.value = v;
  }

  static void setTab(LocalDbService db, String id, bool v) {
    final list = [...tabs.value]..remove(id);
    if (v) list.add(id);
    _write(db, _kTabs, list.join(','));
    tabs.value = list;
  }

  /// Разделы веера, которые сейчас можно показать.
  static List<String> get visibleTabs => [for (final id in tabs.value) if (!suppressed.contains(id)) id];
}
