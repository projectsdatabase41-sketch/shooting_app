import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'logic/ai_context.dart';
import 'services/ai_service.dart';
import 'services/ai_settings.dart';
import 'services/knowledge_service.dart';
import 'services/local_db_service.dart';
import 'state/ai_chat_view_model.dart';
import 'state/app_data_store.dart';
import 'state/personalization_view_model.dart';
import 'screens/home_shell.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = LocalDbService();
  await db.open();
  runApp(ShootingApp(db: db));
}

class ShootingApp extends StatefulWidget {
  final LocalDbService db;

  const ShootingApp({super.key, required this.db});

  @override
  State<ShootingApp> createState() => _ShootingAppState();
}

class _ShootingAppState extends State<ShootingApp> with WidgetsBindingObserver {
  late final AppDataStore _store;
  late final PersonalizationViewModel _personalization;

  /// Разговор с ассистентом — один на всё приложение.
  ///
  /// Пользователь просил, чтобы чат можно было закрыть, посмотреть
  /// что-то на других экранах и вернуться к тому же разговору. Значит,
  /// объект обязан жить дольше экрана — то есть здесь, в корне.
  /// Хранится только в памяти: закрыл приложение — переписка исчезла.
  late final AiChatViewModel _aiChat;

  // Темы строятся один раз: AppTheme.light()/dark() собирают несколько
  // десятков подтем, и пересобирать их на каждой перерисовке незачем.
  final ThemeData _lightTheme = AppTheme.light();
  final ThemeData _darkTheme = AppTheme.dark();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = AppDataStore(widget.db)..loadAll();
    _personalization = PersonalizationViewModel(widget.db)..loadFromDb();

    final aiSettings = AiSettings(widget.db);
    _aiChat = AiChatViewModel(
      service: AiService(aiSettings),
      knowledge: KnowledgeService(aiSettings),
      // Заглушка до первого открытия чата: экран подставит настоящий
      // источник (общий разговор, тренировка или выстрел) сам.
      contextBuilder: () => AiContext(
        scope: AiScope.general,
        allSessions: _store.sessions,
        exerciseNameOf: (s) => _store.exerciseFor(s)?.label ?? 'без упражнения',
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _aiChat.dispose();
    super.dispose();
  }

  /// Сброс базы на диск, когда приложение уходит из фокуса.
  ///
  /// Нужно ради веб-сборки: там база лежит в IndexedDB, запись туда
  /// асинхронная, и между «sqlite записал» и «браузер сохранил» есть
  /// зазор. Закрыл вкладку внутри зазора — последняя серия пропала.
  /// В браузере смена вкладки и закрытие приходят сюда как `hidden` и
  /// `paused`, так что момент ловится вовремя.
  ///
  /// На Windows и Android вызов ничего не делает — там sqlite пишет в
  /// файл сам.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    widget.db.flush();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppDataStore>.value(value: _store),
        ChangeNotifierProvider<PersonalizationViewModel>.value(value: _personalization),
        ChangeNotifierProvider<AiChatViewModel>.value(value: _aiChat),
      ],
      // Selector, а не Consumer: PersonalizationViewModel уведомляет
      // слушателей на КАЖДОЕ изменение цвета мишени (в том числе пока
      // пользователь тянет ползунок в пипетке), а пересобирать всё
      // приложение ради этого не нужно — здесь важна только смена
      // светлой/тёмной темы.
      child: Selector<PersonalizationViewModel, ThemeMode>(
        selector: (_, vm) => vm.themeMode,
        builder: (context, themeMode, _) => MaterialApp(
          title: 'Shooting App',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: themeMode,
          // Личные цвета мишени — отдельная персонализация (часть A), НЕ
          // связана с этой темой (раздел 9 ТЗ): стрелок подбирает цвета
          // мишени под свою видимость, а не под оформление приложения.
          //
          // Стартуем СРАЗУ со списка тренировок, а не с экрана
          // подключения. Облако не обязательно: приложение полностью
          // работает локально, и требовать вход при каждом запуске ради
          // необязательной возможности — значит запирать дверь, за
          // которой ничего нет. Подключение к базе живёт в настройках.
          home: const HomeShell(),
        ),
      ),
    );
  }
}
