import 'package:flutter/material.dart';

import 'app_backdrop.dart';

/// Страница раздела, открытая с плитки главного экрана: обои этого раздела (по теме). Значка плитки на фоне нет — у разделов он и так
/// есть. Сам экран раздела прозрачный поверх обоев.
class TileBackdropPage extends StatelessWidget {
  final IconData icon;
  final Widget child;

  /// id плитки главного экрана: у каждой свои обои (значки по теме раздела).
  final String? id;
  const TileBackdropPage({super.key, required this.icon, required this.child, this.id});

  static const _kinds = {
    'exercises': 'exercises',
    'statistics': 'statistics',
    'tasks': 'tasks',
    'athletes': 'athletes',
    'assistant': 'ai',
    'notes': 'notes',
    'finals': 'finals',
    'messenger': 'messenger',
    'drive': 'drive',
  };

  /// Остальные плитки (сервисы, настройки) — общие обои с робота, заметок и настроек.
  static String kindFor(String? id) => _kinds[id] ?? 'settings';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBackdrop(
      kind: kindFor(id),
      // раздел поверх обоев — с прозрачным фоном экрана
      child: Theme(
        data: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: child,
      ),
    );
  }
}
