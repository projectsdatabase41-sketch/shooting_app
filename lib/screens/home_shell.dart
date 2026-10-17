import 'package:flutter/material.dart';
import '../theme/app_transitions.dart';
import '../widgets/tile_backdrop.dart';
import '../widgets/app_backdrop.dart';
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
import '../widgets/glass_pill.dart';
import '../widgets/home_tabs_bar.dart';
import '../widgets/service_icon_picker.dart';
import '../widgets/assistant_tab.dart';
import '../widgets/role_split.dart';
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
      return true;
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
  Set<String> _suppressedTabs(AppDataStore store) {
    final db = store.db;
    bool on(AppModule m) => ModulesSettings.isOn(db, m);
    final noAthletes = CoachAccessService(db).listAthletes().isEmpty;
    AiContext.notesEnabled = on(AppModule.notes);
    return {
      if (!store.isAthlete) 'exercises',
      if (!store.isCoach) 'athletes',
      // Статистика и задания: свои — у спортсмена, спортсменов — у тренера;
      // тренеру без подключённых спортсменов показывать нечего.
      if (!store.isAthlete && (!store.isCoach || noAthletes)) ...{'statistics', 'tasks'},
      if (!on(AppModule.assistant)) 'assistant',
      if (!on(AppModule.messenger)) 'messenger',
      if (!on(AppModule.notes)) 'notes',
      // Финалы — только в режиме разработчика и при включённом модуле.
      if (!friendlyErrorDevMode || !on(AppModule.finals)) 'finals',
      if (!on(AppModule.services))
        for (final s in _services.list()) '$serviceTabPrefix${s.id}',
      // «Настройки» живут в шапке справа вверху, а не плиткой.
      'settings',
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final tabs = _tabs;
    tabs.suppressed = _suppressedTabs(store);

    return AnimatedBuilder(
      // И сервисы тоже: переименование не меняет набор вкладок (id те же),
      // а подпись плитки должна обновиться сразу.
      animation: Listenable.merge([tabs, _services, ModulesSettings.revision]),
      builder: (context, _) {
        tabs.suppressed = _suppressedTabs(store);
        // Главный экран — один рабочий стол из плиток (страничного режима с
        // нижней навигацией нет): вкладки открываются отдельным экраном по
        // тапу, «Настройки» — шестерёнка в шапке справа вверху.
        final specs = _specsWithServices();
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassHeader(
              title: const Text('Nexus', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 30, letterSpacing: 1.5, height: 1)),
              actions: [
                IconButton(
                  tooltip: tr('Настройки'),
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => _pageFor('settings', store, tabs))),
                ),
              ]),
          body: AppBackdrop(
            kind: 'home',
            child: Column(
            children: [
              if (store.isBackgroundSyncing) const _SyncBanner(),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height),
                  child: HomeTileGrid(
                    vm: tabs,
                    specs: specs,
                    onSelect: (id) {
                      DemoMode.tab = id; // для отзывов в режиме «Демо»
                      final icon = specs[id]?.icon;
                      final page = icon == null
                          ? _pageFor(id, store, tabs)
                          : TileBackdropPage(icon: icon, child: _pageFor(id, store, tabs));
                      final from = TileOpen.rect;
                      if (AnimSettings.enabled && AnimSettings.type == AnimType.morph && icon != null && from != null) {
                        Navigator.of(context).push(MorphRoute(page: page, icon: icon, from: from));
                      } else {
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
                      }
                    },
                  ),
                ),
              ),
            ],
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
      'statistics' => RoleSplit(athlete: const StatisticsScreen(), coach: const CoachStatisticsScreen()),
      'tasks' => RoleSplit(athlete: const AthleteTasksScreen(), coach: const CoachTasksScreen()),
      'athletes' => const CoachAthletesScreen(),
      // Чат с ассистентом без привязки к тренировке (решение
      // пользователя: «чат с ИИ без выбора тренировок, на главный
      // экран»). Тот же экран открывается и из шапки мишени, но там —
      // с контекстом конкретной тренировки.
      'assistant' => const AssistantTab(),
      'notes' => const CoachDiaryNotesScreen(),
      'finals' => const FinalsScreen(),
      'messenger' => ChatHomeScreen(
          onClose: null),
      _ => SettingsScreen(homeTabs: tabs, services: _services),
    };
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
