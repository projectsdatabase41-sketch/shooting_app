import 'package:flutter/material.dart';

import '../logic/ai_context.dart';
import 'ai_chat_screen.dart';

/// "Чат с ИИ" тренера (раздел 8 ТЗ) — общий разговор с ассистентом, тот
/// же принцип, что и у спортсмена, только `coachMode: true` (ассистент
/// вправе предлагать заметку в дневник тренера). Выбор спортсмена здесь
/// не нужен (решение пользователя, пункт 4 списка правок по тренеру) —
/// для разбора данных КОНКРЕТНОГО спортсмена есть отдельная вкладка
/// "Статистика".
class CoachAiChatScreen extends StatelessWidget {
  const CoachAiChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Свой Scaffold чата (стеклянная шапка, «Очистить»), как у спортсмена.
    return const AiChatScreen(scope: AiScope.general, coachMode: true);
  }
}
