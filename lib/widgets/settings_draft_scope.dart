import 'package:flutter/material.dart';

import '../services/local_db_service.dart';
import 'glass_pill.dart';

/// Экран настроек «с отменой»: пока открыт, изменения видны сразу (предпросмотр), но «Назад»
/// возвращает всё как было, а галочка вверху справа ([SettingsDraftScope.confirmButton]) сохраняет.
///
/// При входе запоминается содержимое таблицы настроек (`color_prefs`); при отмене оно
/// восстанавливается и вызывается [onRestored] (экраны перечитывают свои модели).
class SettingsDraftScope extends StatefulWidget {
  final LocalDbService db;
  final VoidCallback onRestored;
  final Widget child;
  const SettingsDraftScope({super.key, required this.db, required this.onRestored, required this.child});

  /// Кнопка-галочка для шапки: подтверждает изменения и закрывает экран.
  static Widget confirmButton(BuildContext context, {String tooltip = 'Сохранить'}) => GlassCircleButton(
        icon: const BoldIcon(Icons.check),
        tooltip: tooltip,
        onTap: () {
          context.findAncestorStateOfType<_SettingsDraftScopeState>()?._committed = true;
          Navigator.of(context).pop();
        },
      );

  @override
  State<SettingsDraftScope> createState() => _SettingsDraftScopeState();
}

class _SettingsDraftScopeState extends State<SettingsDraftScope> {
  late final Map<String, String> _snapshot;
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    // Снимок делаем сразу при входе (не лениво): иначе он снялся бы уже после правок.
    _snapshot = {
      for (final r in widget.db.db.select('SELECT key, hex FROM color_prefs')) '${r['key']}': '${r['hex'] ?? ''}',
    };
  }

  void _restore() {
    final db = widget.db.db;
    for (final r in db.select('SELECT key, hex FROM color_prefs')) {
      final k = '${r['key']}';
      if (!_snapshot.containsKey(k)) db.execute('DELETE FROM color_prefs WHERE key = ?', [k]);
    }
    for (final e in _snapshot.entries) {
      db.execute('INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [e.key, e.value]);
    }
    widget.onRestored();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // «Назад» (кнопка или жест) — отмена: всё возвращается как было.
          if (!_committed) _restore();
          Navigator.of(context).pop();
        },
        child: widget.child,
      );
}
