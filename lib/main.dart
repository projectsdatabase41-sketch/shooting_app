import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'logic/ai_context.dart';
import 'services/ai_memory_service.dart';
import 'services/ai_service.dart';
import 'services/ai_settings.dart';
import 'services/chat_auth_service.dart';
import 'services/chat_messages_repository.dart';
import 'services/chat_preferences.dart';
import 'services/chat_sync_service.dart';
import 'services/firebase_settings.dart';
import 'services/knowledge_service.dart';
import 'services/local_db_service.dart';
import 'services/push_service.dart';
import 'services/supabase_auth_service.dart';
import 'state/ai_chat_view_model.dart';
import 'state/app_data_store.dart';
import 'state/personalization_view_model.dart';
import 'screens/chat_home_screen.dart';
import 'screens/chat_thread_screen.dart';
import 'screens/home_shell.dart';
import 'theme/app_theme.dart';

/// Один навигатор на всё приложение — нужен, чтобы открыть конкретный
/// чат по тапу на push-уведомление (см. `push_service.dart`) из места,
/// где нет BuildContext текущего экрана: холодный старт приложения
/// именно с этого тапа приходит раньше, чем отрисуется первый экран.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Обработчик фонового push должен быть зарегистрирован ДО первого
  // сообщения, поэтому здесь, до runApp (см. push_service.dart).
  if (FirebaseSettings.isConfigured &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  final db = LocalDbService();
  try {
    // На вебе открытие идёт через IndexedDB + wasm-сборку sqlite (см.
    // db_opener_web.dart) — на части версий iOS Safari это иногда зависает
    // без единой ошибки в консоли (сам браузер ни о чём не сообщает,
    // просто не отвечает). Без таймаута пользователь видит вечное
    // "Загрузка…" из index.html и не может понять, ждать ещё или нет.
    await db.open().timeout(const Duration(seconds: 30));
  } catch (e) {
    runApp(_DbOpenFailedApp(error: e));
    return;
  }
  runApp(ShootingApp(db: db));
}

/// Экран на случай, если базу так и не удалось открыть (см. комментарий
/// выше) — вместо бесконечно висящей заглушки из index.html хотя бы
/// понятно, что пошло не так, и что попробовать.
class _DbOpenFailedApp extends StatelessWidget {
  final Object error;
  const _DbOpenFailedApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text('Не удалось открыть базу данных', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text('$error', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  const Text(
                    'Попробуйте перезагрузить страницу. Если не поможет — очистите данные сайта в настройках браузера.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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

    // Холодный старт по тапу на push (уже вошедшего в чат пользователя) —
    // ChatHomeScreen мог ещё ни разу не открыться в этой сессии, значит
    // и getInitialMessage() внутри PushService.init() тоже. Если чат ещё
    // не настроен или пользователь не входил — init() сам ничего не делает.
    pushChatTapHandler = _openChatFromPush;
    final chatAuth = ChatAuthService(widget.db);
    if (chatAuth.isSignedIn) PushService(chatAuth).init();

    final aiSettings = AiSettings(widget.db);
    _aiChat = AiChatViewModel(
      service: AiService(aiSettings),
      knowledge: KnowledgeService(
        aiSettings,
        db: widget.db,
        aiService: AiService(aiSettings),
        personalAuth: SupabaseAuthService(widget.db),
      ),
      memory: AiMemoryService(SupabaseAuthService(widget.db)),
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

  /// Открывает нужный чат по тапу на уведомление (см.
  /// `push_service.dart`). Общий чат — просто ChatHomeScreen (это и есть
  /// его главный экран); личный — сначала опрашивает сервер, чтобы
  /// первое сообщение от ещё незнакомого контакта успело завести его
  /// локально (см. `ChatSyncService.pollIncoming`), иначе для чужого
  /// открылся бы список контактов вместо самой переписки.
  Future<void> _openChatFromPush(PushChatTarget target) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final auth = ChatAuthService(widget.db);
    if (!auth.isSignedIn) return;
    final repo = ChatMessagesRepository(widget.db);
    if (target.isGlobal) {
      nav.push(MaterialPageRoute(builder: (_) => const ChatHomeScreen()));
      return;
    }
    final sync = ChatSyncService(auth, repo);
    await sync.pollIncoming();
    final contact = repo.contactById(target.contactId!);
    if (contact == null) {
      nav.push(MaterialPageRoute(builder: (_) => const ChatHomeScreen()));
      return;
    }
    nav.push(MaterialPageRoute(
      builder: (_) => ChatThreadScreen(contact: contact, auth: auth, repo: repo, sync: sync, prefs: ChatPreferences(widget.db)),
    ));
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
          navigatorKey: navigatorKey,
          title: 'Pusl',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: themeMode,
          // null — системный язык устройства (по умолчанию). Сам текст
          // экранов при этом не переводится — см. комментарий у
          // `PersonalizationViewModel.locale`.
          locale: _personalization.locale,
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
