import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';
import 'ai_chat_screen.dart';
import 'coach_diary_screen.dart';
import 'exercises_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';
import 'target_screen.dart';
import 'trainings_history_screen.dart';

/// Домашняя оболочка с нижней навигацией. Состав вкладок зависит от
/// `workMode` (часть C.1 логики-спека). По решению пользователя — состав
/// СПОРТСМЕНА из 5 вкладок по макетам (часть C.6):
/// Тренировка · История · Мишень (центр) · Статистика · Настройки.
/// Тренер — Дневник · Настройки (раздел 8/9 ТЗ, макетов с 5 вкладками
/// для тренера не присылали).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _athleteIndex = 2; // старт на вкладке "Мишень"
  int _coachIndex = 0;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final isCoach = store.workMode == WorkMode.coach;

    if (isCoach) {
      final pages = [const CoachDiaryScreen(), const SettingsScreen()];
      return Scaffold(
        body: pages[_coachIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _coachIndex,
          onDestinationSelected: (i) => setState(() => _coachIndex = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'Дневник'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
          ],
        ),
      );
    }

    final pages = [
      const ExercisesScreen(),
      const TrainingsHistoryScreen(),
      _ActiveTargetTab(key: ValueKey(_activeSessionKey(store))),
      const StatisticsScreen(),
      // Чат с ассистентом без привязки к тренировке (решение
      // пользователя: «чат с ИИ без выбора тренировок, на главный
      // экран»). Тот же экран открывается и из шапки мишени, но там —
      // с контекстом конкретной тренировки.
      const AiChatScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: pages[_athleteIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _athleteIndex,
        onDestinationSelected: (i) => setState(() => _athleteIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Тренировка'),
          NavigationDestination(icon: Icon(Icons.history), label: 'История'),
          NavigationDestination(icon: Icon(Icons.gps_fixed), label: 'Мишень'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Статистика'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Ассистент'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }

  String _activeSessionKey(AppDataStore store) {
    final active = store.sessions.where((s) => s.status == SessionStatus.running || s.status == SessionStatus.paused);
    return active.isEmpty ? 'none' : active.first.id;
  }
}

/// Центральная вкладка "Мишень" — показывает активную (running/paused)
/// тренировку, если она есть, иначе предлагает начать новую с вкладки
/// "Тренировка" (раздел 5.1 ТЗ: тренер не создаёт тренировки — это
/// действие спортсмена).
class _ActiveTargetTab extends StatelessWidget {
  const _ActiveTargetTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final active = store.sessions.where(
      (s) => s.status == SessionStatus.running || s.status == SessionStatus.paused,
    );
    if (active.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Мишень')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Нет активной тренировки. Выберите упражнение на вкладке '
              '"Тренировка", чтобы начать.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final session = active.first;
    final exercise = store.exerciseFor(session);
    if (exercise == null) {
      return const Scaffold(body: Center(child: Text('Упражнение не найдено')));
    }
    return TargetScreen(session: session, exercise: exercise, embedded: true);
  }
}
