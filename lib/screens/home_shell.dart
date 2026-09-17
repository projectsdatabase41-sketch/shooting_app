import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/home_tab_specs.dart';
import '../models/training_session.dart';
import '../services/custom_services_repository.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';
import '../widgets/finished_edit_exit_dialog.dart';
import '../widgets/home_tabs_bar.dart';
import '../widgets/service_icon_picker.dart';
import 'ai_chat_screen.dart';
import 'coach_ai_chat_screen.dart';
import 'coach_athletes_screen.dart';
import 'coach_diary_notes_screen.dart';
import 'coach_statistics_screen.dart';
import 'coach_tasks_screen.dart';
import 'chat_home_screen.dart';
import 'exercises_screen.dart';
import 'service_tile_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';
import 'target_screen.dart';

/// Домашняя оболочка с нижней навигацией. Состав вкладок зависит от
/// `workMode` (часть C.1 логики-спека). Порядок и видимость каждой
/// вкладки пользователь настраивает сам — долгое нажатие на значок в
/// нижней навигации (см. `HomeTabsBar`) и раздел "Рабочие пространства"
/// в настройках.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _athleteTab = 'target';
  String _coachTab = 'diary';
  WorkMode? _lastMode;

  late final HomeTabsViewModel _athleteTabs;
  late final HomeTabsViewModel _coachTabs;
  late final CustomServicesRepository _services;
  late final PersonalizationViewModel _personalization;

  /// Вкладки недоделанных функций — скрыты от обычных пользователей,
  /// пока не включён "режим разработчика" (решение пользователя: чат
  /// между пользователями и задания тренера ещё не готовы к нагрузке
  /// реальных пользователей). Не про удаление функции, только про то,
  /// чтобы её не увидели раньше времени — сам код никуда не делся.
  static const _devOnlyTabIds = {'messenger', 'tasks'};

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    _athleteTabs = HomeTabsViewModel(db, mode: 'athlete', allIds: athleteTabIds, unhidable: athleteUnhidable);
    _coachTabs = HomeTabsViewModel(db, mode: 'coach', allIds: coachTabIds, unhidable: coachUnhidable);
    _services = CustomServicesRepository(db);
    _personalization = context.read<PersonalizationViewModel>();
    _services.addListener(_onServicesChanged);
    _personalization.addListener(_onServicesChanged);
    _onServicesChanged(); // сервисы, добавленные в прошлой сессии
  }

  @override
  void dispose() {
    _services.removeListener(_onServicesChanged);
    _personalization.removeListener(_onServicesChanged);
    super.dispose();
  }

  /// Плитки сервисов — общие для обоих режимов (решение пользователя не
  /// уточняло разделение по ролям, а разделять было бы лишней сложностью
  /// без явной причины). Заодно пересчитывается при включении/выключении
  /// режима разработчика — те же id, просто с учётом `_devOnlyTabIds`.
  void _onServicesChanged() {
    final devMode = _personalization.devMode;
    final serviceIds = [for (final s in _services.list()) '$serviceTabPrefix${s.id}'];
    List<String> withDevFilter(List<String> ids) =>
        devMode ? ids : ids.where((id) => !_devOnlyTabIds.contains(id)).toList();
    _athleteTabs.setAllIds([...withDevFilter(athleteTabIds), ...serviceIds]);
    _coachTabs.setAllIds([...withDevFilter(coachTabIds), ...serviceIds]);
  }

  Map<String, HomeTabSpec> _specsWithServices() => {
        ...homeTabSpecs,
        for (final s in _services.list())
          '$serviceTabPrefix${s.id}': HomeTabSpec(icon: iconForService(s.iconName), label: s.name),
      };

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final isCoach = store.workMode == WorkMode.coach;
    final tabs = isCoach ? _coachTabs : _athleteTabs;

    // Рубильник "Режим тренера" переключают со страницы настроек —
    // после смены роли логичнее увидеть домашнюю вкладку нового режима
    // (Дневник у тренера, Мишень у спортсмена), а не ту, на которой
    // листали до переключения (обычно это и есть сами настройки).
    if (_lastMode != null && _lastMode != store.workMode) {
      if (isCoach) {
        _coachTab = 'diary';
      } else {
        _athleteTab = 'target';
      }
    }
    _lastMode = store.workMode;

    return AnimatedBuilder(
      animation: tabs,
      builder: (context, _) {
        // Режим "плитки" (решение пользователя) — один рабочий стол,
        // вкладки открываются отдельным экраном по тапу, а не в этом же
        // Scaffold: своей "текущей вкладки" тут нет, поэтому и
        // проверка несохранённых правок (см. _onDestinationSelected) не
        // нужна — уход с экрана мишени идёт обычным Navigator.pop,
        // который PopScope самого TargetScreen и так видит.
        final specs = _specsWithServices();

        if (tabs.layout == 'tiles') {
          return Scaffold(
            appBar: AppBar(title: const Text('Pusl')),
            body: Column(
              children: [
                if (store.isBackgroundSyncing) const _SyncBanner(),
                Expanded(
                  child: HomeTileGrid(
                    vm: tabs,
                    specs: specs,
                    onSelect: (id) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => _pageFor(id, store, isCoach, tabs)),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final selected = isCoach ? _coachTab : _athleteTab;
        // Скрыли вкладку, на которой стояли — переезжаем на первую
        // оставшуюся видимую, а не оставляем экран без вкладки вовсе.
        final current = tabs.visible.contains(selected) ? selected : tabs.visible.first;
        final homeTabId = isCoach ? 'diary' : 'target';

        // Вкладки в "страничном" режиме — не отдельные маршруты
        // Navigator (только один Scaffold на весь HomeShell, тело
        // подменяется по тапу на нижней панели), поэтому без этого
        // PopScope системный жест "назад" на любой вкладке, кроме
        // домашней, сразу закрывал приложение — свернуть было некуда,
        // ведь для Navigator это был единственный маршрут (жалоба
        // пользователя: "в некоторых окнах он полностью закрывает
        // приложение"). Теперь сперва возвращает на домашнюю вкладку,
        // как в большинстве приложений с нижней навигацией.
        return PopScope(
          canPop: current == homeTabId,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _onDestinationSelected(context, store, isCoach, homeTabId);
          },
          child: Scaffold(
            body: Column(
              children: [
                if (store.isBackgroundSyncing) const _SyncBanner(),
                Expanded(child: _pageFor(current, store, isCoach, tabs)),
              ],
            ),
            bottomNavigationBar: HomeTabsBar(
              vm: tabs,
              specs: specs,
              selected: current,
              onSelect: (id) => _onDestinationSelected(context, store, isCoach, id),
            ),
          ),
        );
      },
    );
  }

  // `HomeTabsViewModel` передаётся явно, а не через Provider — экран
  // настроек открывается через `Navigator.push` НА КОРНЕВОЙ навигатор
  // приложения (у HomeShell нет своего), а Provider, объявленный внутри
  // поддерева HomeShell, пушнутому поверх всего маршруту не виден
  // (см. `SettingsHomeTabsScreen`).
  Widget _pageFor(String id, AppDataStore store, bool isCoach, HomeTabsViewModel tabs) {
    if (id.startsWith(serviceTabPrefix)) {
      final service = _services.byId(id.substring(serviceTabPrefix.length));
      if (service != null) return ServiceTileScreen(service: service, repo: _services);
    }
    if (isCoach) {
      return switch (id) {
        'diary' => const CoachDiaryNotesScreen(),
        'athletes' => const CoachAthletesScreen(),
        'statistics_coach' => const CoachStatisticsScreen(),
        'assistant_coach' => const CoachAiChatScreen(),
        'tasks' => const CoachTasksScreen(),
        'messenger' => const ChatHomeScreen(),
        _ => SettingsScreen(homeTabs: tabs, services: _services),
      };
    }
    return switch (id) {
      'exercises' => const ExercisesScreen(),
      'target' => _ActiveTargetTab(key: ValueKey(_activeSessionKey(store))),
      'statistics' => const StatisticsScreen(),
      // Чат с ассистентом без привязки к тренировке (решение
      // пользователя: «чат с ИИ без выбора тренировок, на главный
      // экран»). Тот же экран открывается и из шапки мишени, но там —
      // с контекстом конкретной тренировки.
      'assistant' => const AiChatScreen(),
      'messenger' => const ChatHomeScreen(),
      _ => SettingsScreen(homeTabs: tabs, services: _services),
    };
  }

  /// Переключение нижней вкладки — не Navigator.pop, поэтому PopScope
  /// экрана мишени его не видит: без этой проверки правки в
  /// разблокированной завершённой тренировке терялись бы молча при
  /// уходе на другую вкладку (пункт 13 списка правок; на практике
  /// сейчас недостижимо — вкладка "Мишень" показывает только
  /// running/paused тренировки, а редактирование завершённой открыто
  /// отдельным экраном из истории — но это дешёвая защита на будущее,
  /// если это когда-нибудь изменится).
  Future<void> _onDestinationSelected(BuildContext context, AppDataStore store, bool isCoach, String id) async {
    final current = isCoach ? _coachTab : _athleteTab;
    if (id != current && store.hasUnsavedFinishedEdit) {
      final keep = await confirmFinishedEditExit(context);
      if (keep == null) return; // остаёмся на текущей вкладке
      store.resolvePendingFinishedEdit?.call(keep: keep);
    }
    setState(() {
      if (isCoach) {
        _coachTab = id;
      } else {
        _athleteTab = id;
      }
    });
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
