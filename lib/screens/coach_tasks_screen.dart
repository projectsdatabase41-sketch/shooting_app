import 'package:flutter/material.dart';

import '../widgets/empty_state.dart';

/// "Задания" — задачи тренера для спортсменов (раздел 8 ТЗ). Пока в
/// разработке — пользователь прямо это указал.
class CoachTasksScreen extends StatelessWidget {
  const CoachTasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Задания')),
      body: const EmptyState(icon: Icons.assignment_outlined, text: 'В разработке'),
    );
  }
}
