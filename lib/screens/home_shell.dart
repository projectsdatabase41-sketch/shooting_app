import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../logic/ai_context.dart';
import '../models/home_tab_specs.dart';
import '../models/training_session.dart';
import '../services/custom_services_repository.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_background_poll.dart';
import '../services/coach_access_service.dart';
import '../services/modules_settings.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';
import '../widgets/finished_edit_exit_dialog.dart';
import '../widgets/glass_pill.dart';
import '../widgets/home_tabs_bar.dart';
import '../widgets/service_icon_picker.dart';
import 'ai_chat_screen.dart';
import 'coach_ai_chat_screen.dart';
import 'coach_athletes_screen.dart';
import 'coach_diary_notes_screen.dart';
import 'coach_statistics_screen.dart';
import '../tasks/athlete_tasks_screen.dart';
import '../tasks/coach_tasks_screen.dart';
import 'chat_home_screen.dart';
import '../services/demo_mode.dart';
import 'exercises_screen.dart';
import 'finals_screen.dart';
import 'service_tile_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';
import 'target_screen.dart';
import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';

/// Домашняя оболочка с нижней навигацией. Состав вкладок задают включённые
/// модули (режима «спортсмен / тренер» больше нет). Порядок и видимость каждой
/// вкладки пользователь настраивает сам — долгое нажатие на значок в
/// нижней навигации (см. `HomeTabsBar`) и раздел "Рабочие пространства"
/// в настройках.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// Текущая вкладка («страничная» раскладка).
  String _tab = 'exercises';

  /// Вкладка, открытая до мессенджера, — туда его «сворачивает» кнопка
  /// закрытия (см. ChatHomeScreen.close).
  String? _beforeMessenger;

  late final HomeTabsViewModel _tabs;
  late final CustomServicesRepository _services;
  late final PersonalizationViewModel _personalization;
  ChatBackgroundPoll? _chatPoll;

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    _tabs = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    _services = CustomServicesRepository(db);
    _personalization = context.read<PersonalizationViewModel>();
    _services.addListener(_onServicesChanged);
    _personalization.addListener(_onServicesChanged);
    _onServicesChanged(); // сервисы, добавленные в прошлой сессии
    _chatPoll = ChatBackgroundPoll(db, shouldPoll: () {
      if (!ModulesSettings.isOn(db, AppModule.messenger) || ChatHomeScreen.isOpen) return false;
      return _tab != 'messenger';
    });
    _syncChatPoll();
    ModulesSettings.revision.addListener(_syncChatPoll);
  }

  /// Фоновый опрос нужен только при включённом мессенджере и входе в него
  /// (новые установки и тесты таймеров не создают).
  void _syncChatPoll() {
    final db = context.read<AppDataStore>().db;
    final on = ModulesSettings.isOn(db, AppModule.messenger) &&
        ChatAuthService(db).isSignedIn;
    on ? _chatPoll?.start() : _chatPoll?.stop();
  }

  @override
  void dispose() {
    ModulesSettings.revision.removeListener(_syncChatPoll);
    _chatPoll?.stop();
    _services.removeListener(_onServicesChanged);
    _personalization.removeListener(_onServicesChanged);
    super.dispose();
  }

  /// Плитки сервисов добавляются/убираются во время работы — пересчитываем
  /// набор известных id вкладок.
  void _onServicesChanged() {
    final serviceIds = [
      for (final s in _services.list()) '$serviceTabPrefix${s.id}'
    ];
    _tabs.setAllIds([...allTabIds, ...serviceIds]);
  }

  Map<String, HomeTabSpec> _specsWithServices() => {
        ...homeTabSpecs,
        for (final s in _services.list())
          '$serviceTabPrefix${s.id}':
              HomeTabSpec(icon: iconForService(s.iconName), label: s.name),
      };

  /// Какие вкладки сейчас убраны из показа без изменения сохранённых
  /// настроек: модуль выключен, нет данных (у тренера без спортсменов
  /// нечего показывать в статистике и заданиях) и т. п.
  Set<String> _suppressedTabs(AppDataStore store, {required bool tilesMode}) {
    final db = store.db;
    bool on(AppModule m) => ModulesSettings.isOn(db, m);
    final noAthletes = CoachAccessService(db).listAthletes().isEmpty;
    AiContext.notesEnabled = on(AppModule.notes);
    return {
      if (!store.isAthlete) ...{'exercises', 'statistics', 'tasks'},
      if (!store.isCoach) ...{'athletes', 'statistics_coach', 'tasks_coach', 'assistant_coach'},
      if (store.isCoach && noAthletes) ...{'statistics_coach', 'tasks_coach'},
      if (!on(AppModule.assistant)) ...{'assistant', 'assistant_coach'},
      // Один ассистент: «Ассистент тренера» нужен, только когда включены оба
      // направления, иначе общий ассистент подстраивается под единственное.
      if (!on(AppModule.messenger)) 'messenger',
      if (!on(AppModule.notes)) 'notes',
      // Финалы — только в режиме разработчика и при включённом модуле.
      if (!friendlyErrorDevMode || !on(AppModule.finals)) 'finals',
      if (!on(AppModule.services))
        for (final s in _services.list()) '$serviceTabPrefix${s.id}',
      // В режиме плиток «Настройки» живут в шапке справа вверху, а не плиткой.
      if (tilesMode) 'settings',
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final tabs = _tabs;
    tabs.suppressed = _suppressedTabs(store, tilesMode: tabs.layout == 'tiles');
    DemoMode.tab = _tab; // для отзывов в режиме «Демо»

    return AnimatedBuilder(
      // И сервисы тоже: переименование не меняет набор вкладок (id те же),
      // а подпись плитки должна обновиться сразу.
      animation: Listenable.merge([tabs, _services, ModulesSettings.revision]),
      builder: (context, _) {
        tabs.suppressed = _suppressedTabs(store, tilesMode: tabs.layout == 'tiles');
        // Режим "плитки" (решение пользователя) — один рабочий стол,
        // вкладки открываются отдельным экраном по тапу, а не в этом же
        // Scaffold: своей "текущей вкладки" тут нет, поэтому и
        // проверка несохранённых правок (см. _onDestinationSelected) не
        // нужна — уход с экрана мишени идёт обычным Navigator.pop,
        // который PopScope самого TargetScreen и так видит.
        final specs = _specsWithServices();

        if (tabs.layout == 'tiles') {
          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: GlassHeader(
                title: const Text('Nexus',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                actions: [
                  IconButton(
                    tooltip: tr('Настройки'),
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _pageFor('settings', store, tabs))),
                  ),
                ]),
            body: Column(
              children: [
                if (store.isBackgroundSyncing) const _SyncBanner(),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        top: MediaQuery.paddingOf(context).top +
                            GlassHeader.height),
                    child: HomeTileGrid(
                      vm: tabs,
                      specs: specs,
                      onSelect: (id) => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => _pageFor(id, store, tabs)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final homeTabId = tabs.visible.isEmpty ? 'settings' : tabs.visible.first;
        // Скрыли вкладку, на которой стояли — переезжаем на первую
        // оставшуюся видимую, а не оставляем экран без вкладки вовсе.
        final current = tabs.visible.contains(_tab) ? _tab : homeTabId;

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
            _onDestinationSelected(context, store, homeTabId);
          },
          child: Scaffold(
            body: Column(
              children: [
                if (store.isBackgroundSyncing) const _SyncBanner(),
                Expanded(child: _pageFor(current, store, tabs)),
              ],
            ),
            bottomNavigationBar: HomeTabsBar(
              vm: tabs,
              specs: specs,
              selected: current,
              onSelect: (id) => _onDestinationSelected(context, store, id),
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
  // (см. `SettingsModulesScreen`).
  Widget _pageFor(String id, AppDataStore store, HomeTabsViewModel tabs) {
    // Контекст «спортсмен / тренер» определяется вкладкой, а не режимом.
    store.setContextSilently(coachTabSet.contains(id) ? WorkMode.coach : WorkMode.athlete);
    if (id.startsWith(serviceTabPrefix)) {
      final service = _services.byId(id.substring(serviceTabPrefix.length));
      if (service != null)
        return ServiceTileScreen(service: service, repo: _services);
    }
    return switch (id) {
      // Запущена тренировка — плитка открывает её (мишень), иначе список
      // упражнений (решение пользователя: отдельная «Мишень» без
      // тренировки бесполезна).
      'exercises' => _ActiveTargetTab(key: ValueKey(_activeSessionKey(store))),
      'statistics' => const StatisticsScreen(),
      'tasks' => const AthleteTasksScreen(),
      'athletes' => const CoachAthletesScreen(),
      'statistics_coach' => const CoachStatisticsScreen(),
      'tasks_coach' => const CoachTasksScreen(),
      // Чат с ассистентом без привязки к тренировке (решение
      // пользователя: «чат с ИИ без выбора тренировок, на главный
      // экран»). Тот же экран открывается и из шапки мишени, но там —
      // с контекстом конкретной тренировки.
      'assistant' => const AiChatScreen(),
      'assistant_coach' => const CoachAiChatScreen(),
      'notes' => const CoachDiaryNotesScreen(),
      'finals' => const FinalsScreen(),
      'messenger' => ChatHomeScreen(
          onClose: tabs.layout == 'tiles' ? null : () => _leaveMessenger(store)),
      _ => SettingsScreen(homeTabs: tabs, services: _services),
    };
  }

  void _leaveMessenger(AppDataStore store) {
    final home = _tabs.visible.isEmpty ? 'settings' : _tabs.visible.first;
    final back = _beforeMessenger ?? home;
    _onDestinationSelected(context, store, back == 'messenger' ? home : back);
  }

  /// Переключение нижней вкладки — не Navigator.pop, поэтому PopScope
  /// экрана мишени его не видит: без этой проверки правки в
  /// разблокированной завершённой тренировке терялись бы молча при
  /// уходе на другую вкладку.
  Future<void> _onDestinationSelected(
      BuildContext context, AppDataStore store, String id) async {
    final current = _tab;
    if (id != current && store.hasUnsavedFinishedEdit) {
      final keep = await confirmFinishedEditExit(context);
      if (keep == null) return; // остаёмся на текущей вкладке
      store.resolvePendingFinishedEdit?.call(keep: keep);
    }
    if (id == 'messenger' && current != 'messenger') _beforeMessenger = current;
    setState(() => _tab = id);
  }

  String _activeSessionKey(AppDataStore store) {
    final active = store.sessions.where((s) =>
        s.status == SessionStatus.running || s.status == SessionStatus.paused);
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
      (s) =>
          s.status == SessionStatus.running || s.status == SessionStatus.paused,
    );
    if (active.isEmpty) return const ExercisesScreen();
    final session = active.first;
    final exercise = store.exerciseFor(session);
    if (exercise == null) {
      return Scaffold(body: Center(child: Text(tr('Упражнение не найдено'))));
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
                  tr('Синхронизация с облаком… не выключайте телефон'),
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
