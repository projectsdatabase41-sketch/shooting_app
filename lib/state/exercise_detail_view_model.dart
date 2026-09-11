import 'package:flutter/foundation.dart';

import '../models/exercise_detail_block.dart';
import '../services/local_db_service.dart';

/// Порядок и видимость блоков экрана просмотра прошлой тренировки —
/// тот же паттерн хранения, что `WorkspaceViewModel` (общий на все
/// тренировки, key-value в `color_prefs`, копировать таблицу под это не
/// стоило).
class ExerciseDetailViewModel extends ChangeNotifier {
  final LocalDbService db;

  ExerciseDetailViewModel(this.db) {
    _load();
  }

  static const String _keyOrder = 'exercise_detail_order';
  static const String _keyHidden = 'exercise_detail_hidden';

  List<ExerciseDetailBlock> _order = ExerciseDetailBlock.defaultOrder;
  Set<ExerciseDetailBlock> _hidden = {};

  List<ExerciseDetailBlock> get order => List.unmodifiable(_order);
  List<ExerciseDetailBlock> get visible => [for (final b in _order) if (!_hidden.contains(b)) b];
  bool isHidden(ExerciseDetailBlock b) => _hidden.contains(b);

  void setHidden(ExerciseDetailBlock b, bool hidden) {
    if (hidden && !b.canHide) return;
    if (hidden) {
      _hidden.add(b);
    } else {
      _hidden.remove(b);
    }
    _persist();
    notifyListeners();
  }

  /// См. `WorkspaceViewModel.move` — та же поправка индекса на единицу:
  /// `ReorderableListView` отдаёт `newIndex` в системе координат списка
  /// ДО удаления перетаскиваемого элемента.
  void move(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _order.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _order.length) target = _order.length - 1;
    if (target == oldIndex) return;

    final list = [..._order];
    final block = list.removeAt(oldIndex);
    list.insert(target, block);
    _order = list;
    _persist();
    notifyListeners();
  }

  void _load() {
    final savedOrder = _read(_keyOrder);
    if (savedOrder.isNotEmpty) {
      final parsed = <ExerciseDetailBlock>[];
      for (final name in savedOrder.split(',')) {
        final b = ExerciseDetailBlock.byName(name.trim());
        if (b != null && !parsed.contains(b)) parsed.add(b);
      }
      for (final b in ExerciseDetailBlock.defaultOrder) {
        if (!parsed.contains(b)) parsed.add(b);
      }
      _order = parsed;
    }

    final savedHidden = _read(_keyHidden);
    if (savedHidden == '-') {
      _hidden = {};
    } else if (savedHidden.isNotEmpty) {
      _hidden = {
        for (final name in savedHidden.split(','))
          if (ExerciseDetailBlock.byName(name.trim()) != null) ExerciseDetailBlock.byName(name.trim())!,
      }..remove(ExerciseDetailBlock.target);
    }
  }

  void _persist() {
    _write(_keyOrder, _order.map((b) => b.name).join(','));
    _write(_keyHidden, _hidden.isEmpty ? '-' : _hidden.map((b) => b.name).join(','));
  }

  String _read(String key) {
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
