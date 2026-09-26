import 'package:flutter/material.dart';

import '../widgets/empty_state.dart';
import '../i18n/i18n.dart';

/// "Задания" — задачи тренера для спортсменов (раздел 8 ТЗ). Пока в
/// разработке — пользователь прямо это указал.
class CoachTasksScreen extends StatelessWidget {
  const CoachTasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Задания'))),
      body: EmptyState(icon: Icons.assignment_outlined, text: tr('В разработке')),
    );
  }
}
