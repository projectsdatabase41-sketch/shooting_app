import 'package:flutter/foundation.dart';

import '../models/workspace_page.dart';
import '../services/local_db_service.dart';

/// Состав и порядок страниц рабочего стола.
///
/// Хранится в той же key-value таблице `color_prefs`, что тема и
/// настройки ассистента: это две строки текста, заводить ради них
/// таблицу и миграцию — лишнее.
///
/// Настройка общая для всех тренировок, а не своя у каждой: рабочий
/// стол — это привычка пользователя, а не свойство конкретной
/// тренировки. Разложил один раз — и везде так.
class WorkspaceViewModel extends ChangeNotifier {
  final LocalDbService db;

  WorkspaceViewModel(this.db) {
    _load();
  }

  static const String keyOrder = 'workspace_order';
  static const String keyHidden = 'workspace_hidden';

  /// Все ключи рабочего стола — чтобы сброс цветов их не снёс.
  static const List<String> allKeys = [keyOrder, keyHidden];

  List<WorkspacePage> _order = WorkspacePage.defaultOrder;
  Set<WorkspacePage> _hidden = {
    for (final p in WorkspacePage.values)
      if (!WorkspacePage.defaultVisible.contains(p)) p,
  };

  /// Все страницы в пользовательском порядке, включая скрытые.
  List<WorkspacePage> get order => List.unmodifiable(_order);

  /// Страницы, которые сейчас листаются свайпом.
  List<WorkspacePage> get visible =>
      [for (final p in _order) if (!_hidden.contains(p)) p];

  /// Спрятанные — их предлагают добавить в обзоре.
  List<WorkspacePage> get hidden =>
      [for (final p in _order) if (_hidden.contains(p)) p];

  bool isHidden(WorkspacePage p) => _hidden.contains(p);

  /// Индекс мишени среди видимых — рабочий стол открывается на ней.
  int get targetIndex {
    final i = visible.indexOf(WorkspacePage.target);
    return i < 0 ? 0 : i;
  }

  void setHidden(WorkspacePage page, bool hidden) {
    // Мишень спрятать нельзя — см. WorkspacePage.canHide.
    if (hidden && !page.canHide) return;
    if (hidden) {
      _hidden.add(page);
    } else {
      _hidden.remove(page);
    }
    _persist();
    notifyListeners();
  }

  /// Перемещает страницу в общем списке (включая скрытые).
  ///
  /// Индексы приходят из `ReorderableListView`, который отдаёт `newIndex`
  /// в системе координат СПИСКА ДО удаления элемента — отсюда поправка
  /// на единицу, без неё перетаскивание вниз промахивается на позицию.
  void move(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _order.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _order.length) target = _order.length - 1;
    if (target == oldIndex) return;

    final list = [..._order];
    final page = list.removeAt(oldIndex);
    list.insert(target, page);
    _order = list;
    _persist();
    notifyListeners();
  }

  void reset() {
    _order = WorkspacePage.defaultOrder;
    _hidden = {
      for (final p in WorkspacePage.values)
        if (!WorkspacePage.defaultVisible.contains(p)) p,
    };
    _persist();
    notifyListeners();
  }

  // ---- Хранение ----

  void _load() {
    final savedOrder = _read(keyOrder);
    if (savedOrder.isNotEmpty) {
      final parsed = <WorkspacePage>[];
      for (final name in savedOrder.split(',')) {
        final p = WorkspacePage.byName(name.trim());
        if (p != null && !parsed.contains(p)) parsed.add(p);
      }
      // Страницы, добавленные в новой версии приложения, в сохранённом
      // порядке отсутствуют — дописываем их в конец, иначе после
      // обновления они бы просто пропали.
      for (final p in WorkspacePage.defaultOrder) {
        if (!parsed.contains(p)) parsed.add(p);
      }
      _order = parsed;
    }

    // ВАЖНО: проверяем «есть ли запись», а не «непустая ли она».
    //
    // Здесь был баг: когда пользователь открывал ВСЕ страницы, набор
    // скрытых становился пуст, и при чтении пустая строка означала
    // «ничего не сохранено» — раскладка откатывалась к умолчанию.
    // Поэтому пустой набор пишется маркером '-', а маркер отличается
    // от отсутствия записи здесь, а не внутри _read.
    final savedHidden = _readRaw(keyHidden);
    if (savedHidden == '-') {
      _hidden = {};
    } else if (savedHidden.isNotEmpty) {
      _hidden = {
        for (final name in savedHidden.split(','))
          if (WorkspacePage.byName(name.trim()) != null) WorkspacePage.byName(name.trim())!,
      }..remove(WorkspacePage.target);
    }
  }

  void _persist() {
    _write(keyOrder, _order.map((p) => p.name).join(','));
    // Пустая строка означала бы «ничего не сохранено» и при следующем
    // запуске вернула бы значения по умолчанию. Поэтому у пустого
    // набора пишем явный маркер.
    _write(keyHidden, _hidden.isEmpty ? '-' : _hidden.map((p) => p.name).join(','));
  }

  String _read(String key) => _readRaw(key);

  /// Значение как есть, вместе с маркером пустоты '-'.
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
