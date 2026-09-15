import 'package:flutter/foundation.dart';

import '../services/local_db_service.dart';

/// Порядок и видимость вкладок нижней навигации главного экрана —
/// раздельно для спортсмена и тренера (наборы вкладок разные), тот же
/// принцип хранения (строки в key-value таблице `color_prefs`), что у
/// `WorkspaceViewModel` (порядок/видимость страниц ВНУТРИ тренировки).
///
/// В отличие от `WorkspaceViewModel`, скрытые вкладки не хранят
/// "замороженную" позицию среди видимых — им это не нужно: они нигде не
/// показываются упорядоченным списком, кроме отдельного раздела в
/// настройках ("Рабочие пространства"), а при возврате просто
/// дописываются в конец видимых.
class HomeTabsViewModel extends ChangeNotifier {
  final LocalDbService db;
  final String mode;

  /// Все известные id вкладок этого режима — источник истины при первом
  /// запуске и при появлении новой вкладки в будущей версии приложения
  /// (её не было ни в сохранённых видимых, ни в скрытых — по умолчанию
  /// видима, дописывается в конец).
  final List<String> allIds;

  /// Вкладки, которые нельзя скрыть (например, "Мишень" — без неё
  /// негде записывать выстрелы; "Настройки" — иначе скрытые вкладки
  /// стало бы неоткуда вернуть).
  final Set<String> unhidable;

  HomeTabsViewModel(this.db, {required this.mode, required this.allIds, required this.unhidable}) {
    _load();
  }

  static const List<String> allKeys = [
    'home_tabs_visible_athlete',
    'home_tabs_hidden_athlete',
    'home_tabs_visible_coach',
    'home_tabs_hidden_coach',
    'home_tabs_layout_athlete',
    'home_tabs_layout_coach',
  ];

  late List<String> _visible = List.of(allIds);
  Set<String> _hidden = {};

  /// 'pages' (по умолчанию) — как обычная нижняя навигация, одна вкладка
  /// на весь экран; 'tiles' — один рабочий стол, все вкладки квадратными
  /// плитками в два столбика (решение пользователя). Выбор/удаление/
  /// порядок — общие для обоих режимов, отображение отличается только
  /// оформлением.
  String _layout = 'pages';
  String get layout => _layout;
  set layout(String value) {
    if (value == _layout) return;
    _layout = value;
    _write('home_tabs_layout_$mode', value);
    notifyListeners();
  }

  List<String> get visible => List.unmodifiable(_visible);

  /// В каноническом порядке `allIds` — просто список, ничего не листают.
  List<String> get hidden => [for (final id in allIds) if (_hidden.contains(id)) id];

  bool isHidden(String id) => _hidden.contains(id);
  bool canHide(String id) => !unhidable.contains(id);

  void hide(String id) {
    if (!canHide(id)) return;
    if (_visible.length <= 1) return; // хотя бы одна вкладка должна остаться
    if (!_visible.remove(id)) return;
    _hidden.add(id);
    _persist();
    notifyListeners();
  }

  void show(String id) {
    if (!_hidden.remove(id)) return;
    if (!_visible.contains(id)) _visible.add(id);
    _persist();
    notifyListeners();
  }

  /// Индексы — из `ReorderableListView` (см. `WorkspaceViewModel.move`,
  /// тот же приём с поправкой на единицу).
  void move(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _visible.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _visible.length) target = _visible.length - 1;
    if (target == oldIndex) return;
    final id = _visible.removeAt(oldIndex);
    _visible.insert(target, id);
    _persist();
    notifyListeners();
  }

  String get _keyVisible => 'home_tabs_visible_$mode';
  String get _keyHidden => 'home_tabs_hidden_$mode';

  void _load() {
    final savedLayout = _readRaw('home_tabs_layout_$mode');
    if (savedLayout.isNotEmpty) _layout = savedLayout;

    final savedVisible = _readRaw(_keyVisible);
    final savedHidden = _readRaw(_keyHidden);
    if (savedVisible.isEmpty && savedHidden.isEmpty) return; // ничего не сохранено — умолчание уже стоит

    final knownIds = allIds.toSet();
    // Только известные id — вкладка, убранная в более новой версии
    // приложения (например, "Тренировки", объединённые с "Упражнениями"),
    // могла остаться в сохранённых строках старой установки.
    final hiddenSet = (savedHidden.isEmpty || savedHidden == '-')
        ? <String>{}
        : savedHidden.split(',').where(knownIds.contains).toSet();
    final visList = savedVisible.isEmpty ? <String>[] : savedVisible.split(',').where(knownIds.contains).toList();

    // id, добавленный в более новой версии приложения — не встречается
    // ни там, ни там: по умолчанию видим, дописывается в конец.
    for (final id in allIds) {
      if (!visList.contains(id) && !hiddenSet.contains(id)) visList.add(id);
    }
    _visible = visList;
    _hidden = hiddenSet..removeAll(unhidable);
  }

  void _persist() {
    _write(_keyVisible, _visible.join(','));
    // Пустая строка означала бы "ничего не сохранено" при следующем
    // чтении — явный маркер для пустого набора скрытых.
    _write(_keyHidden, _hidden.isEmpty ? '-' : _hidden.join(','));
  }

  String _readRaw(String key) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    if (rows.isEmpty) return '';
    return (rows.first['hex'] as String?) ?? '';
  }

  void _write(String key, String value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, value],
    );
  }
}
