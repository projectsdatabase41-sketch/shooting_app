import 'package:flutter/material.dart';

import 'app_backdrop.dart';

/// Страница раздела, открытая с плитки главного экрана: обои (те же, что у
/// настроек: по теме и платформе). Значка плитки на фоне нет — у разделов он и так
/// есть. Сам экран раздела прозрачный поверх обоев.
class TileBackdropPage extends StatelessWidget {
  final IconData icon;
  final Widget child;
  const TileBackdropPage({super.key, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBackdrop(
      kind: 'settings',
      // раздел поверх обоев — с прозрачным фоном экрана
      child: Theme(
        data: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: child,
      ),
    );
  }
}
