import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';
import '../widgets/finished_edit_exit_dialog.dart';
import 'ai_chat_screen.dart';
import 'coach_ai_chat_screen.dart';
import 'coach_athletes_screen.dart';
import 'coach_diary_notes_screen.dart';
import 'coach_statistics_screen.dart';
import 'coach_tasks_screen.dart';
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
  WorkMode? _lastMode;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final isCoach = store.workMode == WorkMode.coach;

    // Рубильник "Режим тренера" переключают со страницы настроек —
    // после смены роли логичнее увидеть домашнюю вкладку нового режима
    // (Дневник у тренера, Мишень у спортсмена), а не ту, на которой
    // листали до переключения (обычно это и есть сами настройки).
    if (_lastMode != null && _lastMode != store.workMode) {
      if (isCoach) {
        _coachIndex = 0;
      } else {
        _athleteIndex = 2;
      }
    }
    _lastMode = store.workMode;

    if (isCoach) {
      // Главный экран тренера (раздел 8 ТЗ): Дневник · Спортсмены ·
      // Статистика · Чат с ИИ · Задания · Настройки. Мульти-спортсменский
      // режим (решение пользователя): "Дневник" со списком тренировок
      // одного подключения заменён на список спортсменов — тап на
      // конкретного открывает его тренировки отдельным экраном.
      final pages = [
        const CoachDiaryNotesScreen(),
        const CoachAthletesScreen(),
        const CoachStatisticsScreen(),
        const CoachAiChatScreen(),
        const CoachTasksScreen(),
        const SettingsScreen(),
      ];
      return Scaffold(
        body: Column(
          children: [
            if (store.isBackgroundSyncing) const _SyncBanner(),
            Expanded(child: pages[_coachIndex]),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _coachIndex,
          onDestinationSelected: (i) => setState(() => _coachIndex = i),
          // Шесть вкладок — тот же приём, что у спортсмена: подпись
          // только у выбранной, иначе не помещаются на узком экране.
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'Дневник'),
            NavigationDestination(icon: Icon(Icons.groups_outlined), label: 'Спортсмены'),
            NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Статистика'),
            NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Ассистент'),
            NavigationDestination(icon: Icon(Icons.assignment_outlined), label: 'Задания'),
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
      body: Column(
        children: [
          if (store.isBackgroundSyncing) const _SyncBanner(),
          Expanded(child: pages[_athleteIndex]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _athleteIndex,
        onDestinationSelected: (i) => _onDestinationSelected(context, store, i),
        // Шесть вкладок на узком экране (375dp и меньше) не помещаются
        // с подписью у каждой — "Тренировка"/"Ассистент"/"Настройки"
        // переносились на две строки или обрезались. Подпись остаётся
        // только у выбранной вкладки — Material-паттерн для навигации
        // с большим числом пунктов, а не сокращение слов до нечитаемого.
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Упражнения'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Тренировки'),
          NavigationDestination(icon: Icon(Icons.gps_fixed), label: 'Мишень'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Статистика'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Ассистент'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }

  /// Переключение нижней вкладки — не Navigator.pop, поэтому PopScope
  /// экрана мишени его не видит: без этой проверки правки в
  /// разблокированной завершённой тренировке терялись бы молча при
  /// уходе на другую вкладку (пункт 13 списка правок; на практике
  /// сейчас недостижимо — вкладка "Мишень" показывает только
  /// running/paused тренировки, а редактирование завершённой открыто
  /// отдельным экраном из истории — но это дешёвая защита на будущее,
  /// если это когда-нибудь изменится).
  Future<void> _onDestinationSelected(BuildContext context, AppDataStore store, int index) async {
    if (index != _athleteIndex && store.hasUnsavedFinishedEdit) {
      final keep = await confirmFinishedEditExit(context);
      if (keep == null) return; // остаёмся на текущей вкладке
      store.resolvePendingFinishedEdit?.call(keep: keep);
    }
    setState(() => _athleteIndex = index);
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

/// Тонкая полоса поверх любой вкладки, пока идёт автосинхронизация после
/// завершения тренировки — предупреждает не выключать телефон посреди
/// записи (пункт 7 списка правок).
class _SyncBanner extends StatelessWidget {
  const _SyncBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Синхронизация с облаком… не выключайте телефон',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
