import '../widgets/glass_route.dart';
import 'security_settings_screen.dart';
import '../services/app_lock.dart';
import '../logic/friendly_error.dart';
import '../widgets/app_backdrop.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/home_tab_specs.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/custom_services_repository.dart';
import '../services/app_update_service.dart';
import '../services/knowledge_column_discovery.dart';
import '../services/supabase_auth_service.dart';
import '../i18n/i18n.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';
import '../widgets/glass_pill.dart';
import '../widgets/home_tabs_bar.dart';
import '../widgets/service_icon_picker.dart';
import 'ai_settings_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_data_screen.dart';
import 'onboarding_screen.dart';
import 'settings_modules_screen.dart';
import 'settings_services_screen.dart';
import '../services/demo_mode.dart';
import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_sync_service.dart';
import '../services/coach_link.dart';
import '../services/modules_settings.dart';

/// Настройки (раздел 9 ТЗ) — сгруппированы по назначению в отдельные
/// "папки" (решение пользователя), вместо одного длинного списка:
/// внешний вид отдельно от данных/синхронизации, часто нужное (ИИ, режим
/// тренера, учётная запись) остаётся на первом экране. Мессенджер сюда
/// больше не относится — теперь это отдельная вкладка главного экрана
/// (`HomeShell`), а не раздел настроек.
class SettingsScreen extends StatelessWidget {
  /// Модель вкладок ТЕКУЩЕГО режима (спортсмен/тренер) — передана явно
  /// от `HomeShell`, а не через Provider (см. комментарий у
  /// `HomeShell._pageFor`).
  final HomeTabsViewModel homeTabs;
  final CustomServicesRepository services;

  const SettingsScreen(
      {super.key, required this.homeTabs, required this.services});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final specs = <String, HomeTabSpec>{
      ...homeTabSpecs,
      for (final s in services.list())
        '$serviceTabPrefix${s.id}':
            HomeTabSpec(icon: iconForService(s.iconName), label: s.name),
    };

    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassHeader(title: _HiddenDevModeToggle()),
      body: AppBackdrop(
        kind: 'settings',
        child: ListView(
        padding: EdgeInsets.fromLTRB(0, topInset + GlassHeader.height, 0, 32),
        children: [
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: Text(tr('Язык')),
            subtitle: Text(SettingsAppearanceScreen.languageLabel(context.watch<PersonalizationViewModel>().localeCode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => SettingsAppearanceScreen.pickLanguage(context, context.read<PersonalizationViewModel>()),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr('Внешний вид')),
            subtitle: Text(tr('Как выглядит приложение')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const SettingsAppearanceScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(tr('ИИ Ассистент')),
            subtitle: Text(tr('Настройка помощника с ИИ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(tr('Данные и синхронизация')),
            subtitle: Text(tr('Резервные копии и обмен данными')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsDataScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(tr('Защита входа')),
            subtitle: Text(AppLock.isEnabled(store.db) ? tr('PIN включён') : tr('PIN и биометрия')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SecuritySettingsScreen(db: store.db)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(tr('Мой профиль')),
            subtitle: Text(tr('Данные о вас')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final db = store.db;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (ctx) => OnboardingScreen(
                    db: db, editing: true, onDone: () => Navigator.of(ctx).pop()),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(tr('Модули')),
            subtitle: Text(tr('Подключаемые дополнительные возможности')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsModulesScreen(tabs: homeTabs, specs: specs)),
            ),
          ),
          if (ModulesSettings.isOn(store.db, AppModule.services))
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(tr('Сервисы')),
              subtitle: Text(
                  tr('Свои плитки с внешними сервисами')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => SettingsServicesScreen(repo: services)),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: DemoMode.enabled,
            builder: (context, on, _) => SwitchListTile(
              secondary: const Icon(Icons.rate_review_outlined),
              title: Text(tr('Режим Демо')),
              subtitle: Text(tr('Кнопка для отзывов на каждой странице')),
              value: on,
              onChanged: (v) => DemoMode.set(store.db, v),
            ),
          ),
          const Divider(height: 24),
          const _UpdateTile(),
        ],
      ),
      ),
    );
  }
}

/// Строка «Учётная запись» внизу настроек.
///
/// Открывает не полноценный экран, а шторку примерно на две трети
/// высоты — решение пользователя. Причина здравая: вход в базу это не
/// раздел приложения, а разовое действие, и отдельный экран со своей
/// кнопкой «назад» под него избыточен.
/// Обновление одной кнопкой — только там, где оно вообще возможно
/// (Android, сборка из CI со встроенным GIT_SHA; локальная/debug-сборка
/// и веб — плитка просто не показывается, сверять не с чем).
class _UpdateTile extends StatefulWidget {
  const _UpdateTile();

  @override
  State<_UpdateTile> createState() => _UpdateTileState();
}

enum _UpdateStage { idle, checking, upToDate, available, downloading, error }

class _UpdateTileState extends State<_UpdateTile> {
  _UpdateStage _stage = _UpdateStage.idle;
  AppUpdateInfo? _info;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Экран мог пересобраться посреди уже идущей загрузки (свернули
    // приложение и вернулись) — подключаемся к ней, а не показываем
    // «ничего не происходит» (и не даём нажать «Обновить» ещё раз, отчего
    // раньше стартовала вторая загрузка поверх первой).
    _attachIfDownloading();
  }

  Future<void> _attachIfDownloading() async {
    if (!await AppUpdateService.downloadActive()) return;
    if (mounted) setState(() => _stage = _UpdateStage.downloading);
    try {
      await AppUpdateService.attachToActiveDownload(onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _stage = _UpdateStage.idle);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _UpdateStage.error;
          _error = friendlyError(e);
        });
      }
    }
  }

  /// Дата сборки установленной версии дд.мм.гггг (`null`, если неизвестна).
  String? _myDate() {
    final t = DateTime.tryParse(AppUpdateService.buildTime)?.toLocal();
    return t == null ? null : DateFormat('dd.MM.yyyy').format(t);
  }

  Future<void> _check() async {
    setState(() => _stage = _UpdateStage.checking);
    try {
      final info = await AppUpdateService.check(strict: true);
      if (!mounted) return;
      setState(() {
        _info = info;
        _stage = info == null ? _UpdateStage.upToDate : _UpdateStage.available;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _UpdateStage.error;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _install() async {
    final info = _info;
    if (info == null) return;
    // Если подпись новой сборки когда-нибудь снова разойдётся со стоящей
    // на телефоне — Android сам потребует снести старое приложение перед
    // установкой нового, а это стирает всю локальную базу (уже
    // случалось однажды). Предупреждаем и напоминаем синхронизироваться
    // заранее — само приложение это никак не обойти, решает Android.
    final proceed = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Перед обновлением')),
        content: Text(tr(
          'Если Android попросит подтвердить удаление текущей версии — это редкий, но возможный случай, '
          'и вместе со старой версией сотрётся вся локальная база на телефоне. Сначала нажмите '
          '«Синхронизировать сейчас» в этом разделе, чтобы данные точно были в облаке.',
        )),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Отмена'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr('Обновить'))),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      _stage = _UpdateStage.downloading;
      _progress = 0;
    });
    try {
      await AppUpdateService.downloadAndInstall(info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      // Дальше решает системный установщик — экран можно просто оставить
      // как есть, приложение необязательно будет перезапущено сразу.
      if (mounted) setState(() => _stage = _UpdateStage.idle);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _UpdateStage.error;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppUpdateService.supported) {
      // Веб сам всегда последняя версия (кеш статики версионный, см.
      // firebase-messaging-sw.js) — кнопка "проверить" тут не нужна, но
      // время сборки полезно свериться, что открылась не старая
      // закешированная версия.
      if (kIsWeb && AppUpdateService.buildTime.isNotEmpty) {
        final built = DateTime.tryParse(AppUpdateService.buildTime)?.toLocal();
        return ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(tr('Версия сайта')),
          subtitle: Text(built == null
              ? AppUpdateService.buildTime
              : DateFormat('dd.MM.yyyy HH:mm').format(built)),
        );
      }
      return const SizedBox.shrink();
    }
    return switch (_stage) {
      _UpdateStage.idle || _UpdateStage.upToDate => ListTile(
          leading: const Icon(Icons.system_update_outlined),
          title: Text(tr('Проверить обновления')),
          subtitle: _stage == _UpdateStage.upToDate
              ? Text(_myDate() == null
                  ? tr('У вас последняя версия')
                  : tr('У вас последняя версия, от {d}', {'d': _myDate()!}))
              : (_myDate() == null && AppUpdateService.appVersion.isEmpty
                  ? null
                  : Text([
                      if (AppUpdateService.appVersion.isNotEmpty) tr('Версия {v}', {'v': AppUpdateService.appVersion}),
                      if (_myDate() != null) tr('от {d}', {'d': _myDate()!}),
                    ].join(' · '))),
          onTap: _check,
        ),
      _UpdateStage.checking => ListTile(
          leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2)),
          title: Text(tr('Проверяю…')),
        ),
      _UpdateStage.available => ListTile(
          leading:
              const Icon(Icons.system_update_outlined, color: Colors.orange),
          title: Text(tr('Доступно обновление')),
          // Только дата новой версии (номер сборки не нужен).
          subtitle: Text([
            if (_info!.version != null) tr('Версия {v}', {'v': _info!.version}),
            if (_info!.publishedAt != null) tr('от {d}', {'d': DateFormat('dd.MM.yyyy').format(_info!.publishedAt!)}),
            if (_info!.version == null && _info!.publishedAt == null) tr('Вышла новая версия'),
          ].join(' · ')),
          trailing:
              FilledButton(onPressed: _install, child: Text(tr('Обновить'))),
        ),
      _UpdateStage.downloading => ListTile(
          leading: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
                strokeWidth: 2, value: _progress > 0 ? _progress : null),
          ),
          title: Text(tr(
              'Скачиваю… {percent}%', {'percent': (_progress * 100).round()})),
        ),
      _UpdateStage.error => ListTile(
          leading: const Icon(Icons.error_outline, color: Colors.red),
          title: Text(tr('Не удалось обновить')),
          subtitle: Text(_error ?? ''),
          // Обновление уже найдено, но скачать не вышло — повторяем скачивание,
          // а не перепроверяем (перепроверка при плохой связи врала «новых нет»).
          onTap: _info != null ? _install : _check,
        ),
    };
  }
}

class AccountTile extends StatelessWidget {
  const AccountTile();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final auth = SupabaseAuthService(store.db);
    final signedIn = auth.isSignedIn;

    return ListTile(
      leading:
          Icon(signedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
      title: Text(tr('Учётная запись')),
      subtitle: Text(
        signedIn
            ? auth.email
            : auth.hasBase
                ? tr('База указана, вход не выполнен')
                : tr('Своя база Supabase не подключена'),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showGlassSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        // Раньше "полосочка" рисовалась САМИ первым элементом внутри
        // ListView — визуально ручка для свайпа, а по факту обычный
        // пункт списка: жест перетаскивания забирал скролл, а не сам
        // лист, и свайп для закрытия не срабатывал. showDragHandle
        // рисует её СНАРУЖИ прокручиваемого содержимого, там, где
        // Flutter сам умеет закрывать лист перетаскиванием.
        showDragHandle: true,
        builder: (_) => ChangeNotifierProvider<AppDataStore>.value(
          value: store,
          child: const _AccountSheet(),
        ),
      ),
    );
  }
}

class _AccountSheet extends StatefulWidget {
  const _AccountSheet();

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  late final SupabaseAuthService _auth;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _email;
  final _password = TextEditingController();

  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  bool _showBaseFields = false;

  @override
  void initState() {
    super.initState();
    _auth = SupabaseAuthService(context.read<AppDataStore>().db);
    _url = TextEditingController(text: _auth.url);
    _key = TextEditingController(text: _auth.anonKey);
    _email = TextEditingController(text: _auth.email);
    // Поля базы раскрыты, пока её нет: без адреса и ключа входить
    // некуда, и прятать их за «показать» на пустом экране незачем.
    _showBaseFields = !_auth.hasBase;
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _saveBase() {
    _auth.setBase(url: _url.text, anonKey: _key.text);
  }

  /// Копирует установочный SQL (lib/db/puls_install.sql — та же схема,
  /// что и в приложении: тренировки, защита, таблица заметок для ИИ,
  /// инструкции в базе, "пульс" для GitHub) в буфер обмена одним нажатием
  /// — дальше только вставить в SQL Editor Supabase и один раз нажать Run.
  /// Полная объяснённая версия с разбивкой по файлам — в репозитории
  /// приложения, папка Puls-Database-Setup.
  Future<void> _copyInstallSql(BuildContext context) async {
    String message;
    try {
      final sql = await rootBundle.loadString('lib/db/nexus_personal_db.sql');
      await Clipboard.setData(ClipboardData(text: sql));
      message =
          tr('SQL скопирован — вставьте в SQL Editor Supabase и нажмите Run');
    } catch (e) {
      // Браузер иногда отказывает в доступе к буферу обмена (нет разрешения,
      // окно не в фокусе) — тогда честно сказать об этом, а не падать молча.
      message = tr('Не удалось скопировать: {e}', {'e': friendlyError(e)});
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final ok = await action();
      if (!mounted) return;
      // "Учётная запись" на самом экране настроек (AccountTile) читает
      // состояние входа из той же локальной базы, но это ДРУГОЙ виджет —
      // без notifyListeners() он не узнаёт о входе/регистрации, пока
      // что-нибудь ещё не вызовет случайную перерисовку (отсюда "вроде
      // подключился, но пишет не подключено — помогает только рестарт").
      context.read<AppDataStore>().refreshView();
      setState(() {
        _message = ok;
        _messageIsError = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.message;
        _messageIsError = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = friendlyError(e);
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTablesPicker(BuildContext context) async {
    List<String> names;
    try {
      names = (await _auth.fetchTableNames())
          .where((n) => !AiSettings.appOwnTables.contains(n))
          .toList();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = friendlyError(e);
        _messageIsError = true;
      });
      return;
    }
    if (!context.mounted) return;
    final settings = AiSettings(context.read<AppDataStore>().db);
    final existing = {for (final t in settings.tables) t.name: t};
    final selected = {for (final n in names) n: existing.containsKey(n)};

    final result = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr('Таблицы для ИИ')),
          content: SizedBox(
            width: double.maxFinite,
            child: names.isEmpty
                ? Text(tr(
                    'В базе не нашлось таблиц, кроме тех, что уже использует само приложение.'))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final n in names)
                          CheckboxListTile(
                            value: selected[n],
                            title: Text(n),
                            onChanged: (v) =>
                                setDialogState(() => selected[n] = v ?? false),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(tr('Отмена'))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(tr('Сохранить'))),
          ],
        ),
      ),
    );
    if (result != true) return;

    settings.tables = [
      for (final n in names)
        if (selected[n] == true) existing[n] ?? KnowledgeTableConfig(name: n),
    ];
    // Отключили таблицу — забываем, какую колонку в ней нашли раньше
    // (решение пользователя): подключат снова, в том числе таблицу с
    // тем же именем, но другой структурой, — колонку определят заново.
    final discovery = KnowledgeColumnDiscovery(settings.db);
    for (final n in existing.keys) {
      if (selected[n] != true) discovery.forget(n);
    }
    if (!mounted || !context.mounted) return;
    // Сохранили — закрываем и лист учётной записи, чтобы было видно, что
    // настройка применилась (решение пользователя).
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    final chosen = settings.tables.map((t) => t.label).join(', ');
    messenger.showSnackBar(SnackBar(
      content: Text(chosen.isEmpty
          ? tr('Таблицы для ИИ отключены')
          : tr('ИИ теперь видит: {chosen}', {'chosen': chosen})),
    ));

    // Понять, что за таблицу подключили: без описания ИИ видит только
    // имя таблицы и колонки, но не знает, дневник это или что-то ещё
    // (пункт: "при добавлении новой базы... ИИ сам запрашивает структуру
    // базы... сохраняет во внутреннюю память, что это за база"). Пустую
    // таблицу описываем только по структуре — само содержание опишется
    // при следующем открытии этого экрана, когда данные уже появятся.
    final needsDescription = settings.tables
        .where((t) => t.description.isEmpty || t.description == _emptyTableNote)
        .toList();
    // Описание — в фоне: лист уже закрыт, результат просто сохранится.
    if (needsDescription.isNotEmpty)
      _describeTables(settings, needsDescription);
  }

  static const _emptyTableNote = 'Таблица пока пустая, содержимого ещё нет.';

  Future<String?> _describeTables(
      AiSettings settings, List<KnowledgeTableConfig> tables) async {
    final token = await _auth.ensureFreshToken() ?? _auth.anonKey;
    final baseUrl = '${_auth.url}/rest/v1';
    final aiService = AiService(settings);
    final updated = {for (final t in settings.tables) t.name: t};
    for (final t in tables) {
      final desc = await _describeOneTable(t, baseUrl, token, aiService);
      if (desc != null) {
        updated[t.name] = KnowledgeTableConfig(
            name: t.name,
            label: t.label,
            description: desc,
            contentColumn: t.contentColumn);
      }
    }
    settings.tables = updated.values.toList();
    return tr('Таблицы для ИИ обновлены');
  }

  Future<String?> _describeOneTable(
    KnowledgeTableConfig t,
    String baseUrl,
    String token,
    AiService aiService,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/${t.name}')
          .replace(queryParameters: {'select': '*', 'limit': '3'});
      final res = await http.get(uri, headers: {
        'apikey': token,
        'Authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final rows = jsonDecode(utf8.decode(res.bodyBytes));
      if (rows is! List) return null;
      if (rows.isEmpty) return _emptyTableNote;

      final firstRow = rows.first;
      if (firstRow is! Map) return null;
      final reply = await aiService.ask(
        task: 'table_describe',
        systemPrompt:
            'You help a shooting app understand the meaning of a FOREIGN database table '
            'the user has connected. You get a list of columns and example rows. Describe in ONE short '
            'sentence what this table is and how its content should be used when answering the user. '
            'No markdown, no quotes, just the essence. Write the sentence in the language of the table content.',
        contextBlock:
            'Table "${t.name}". Columns: ${firstRow.keys.join(", ")}. '
            'Example rows: ${jsonEncode(rows.take(2).toList())}',
        history: const [(role: 'user', text: 'What is this table?')],
      );
      final desc = reply.text.trim();
      return desc.isEmpty ? null : desc;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final signedIn = _auth.isSignedIn;

    return FractionallySizedBox(
      heightFactor: 0.7,
      child: Padding(
        // Отступ снизу равен высоте клавиатуры: иначе поле пароля
        // оказывается под ней ровно в тот момент, когда в него пишут.
        //
        // На вебе — НЕ добавляем: там это сам браузер уже подстраивает
        // видимую область под виртуальную клавиатуру телефона, а
        // `viewInsets.bottom` после ЗАКРЫТИЯ клавиатуры не всегда
        // возвращается ровно к нулю (известная особенность мобильных
        // браузеров) — двойная компенсация оставляла пустой промежуток
        // снизу и уезжавший вверх лист уже после того, как клавиатура
        // скрылась.
        padding: EdgeInsets.only(
            bottom: kIsWeb ? 0 : MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(tr('Учётная запись'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(tr('Подключение к Supabase'),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://supabase.com/dashboard/sign-up'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: Text(tr('Регистрация в Supabase')),
            ),
            const SizedBox(height: 16),
            if (signedIn) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(
                    _auth.email.isEmpty ? tr('Вход выполнен') : _auth.email),
                subtitle: Text(_auth.url,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(_auth.checkSchema),
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(tr('Проверить базу')),
              ),
              const SizedBox(height: 8),
              // Пункт 3/8 списка правок: список таблиц читается из САМОЙ
              // базы (вместо того, чтобы печатать имя таблицы руками в
              // настройках ассистента), а свои внутренние таблицы
              // (тренировки, выстрелы и т.п.) в списке не предлагаются —
              // AiSettings.appOwnTables их отфильтровывает.
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _openTablesPicker(context),
                icon: const Icon(Icons.table_chart_outlined),
                label: Text(tr('Таблицы для ИИ')),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        _auth.signOutLocally();
                        context.read<AppDataStore>().refreshView();
                        setState(() => _message = tr(
                            'Вы вышли. Тренировки на устройстве остались на месте.'));
                      },
                icon: const Icon(Icons.logout),
                label: Text(tr('Выйти')),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        _auth.forgetBase();
                        context.read<AppDataStore>().refreshView();
                        setState(() {
                          _url.text = '';
                          _key.text = '';
                          _showBaseFields = true;
                          _message = tr('База отключена');
                        });
                      },
                icon: Icon(Icons.link_off, color: cs.error),
                label: Text(tr('Отключить базу'),
                    style: TextStyle(color: cs.error)),
              ),
            ] else ...[
              if (_showBaseFields) ...[
                if (!_auth.hasBase) ...[
                  // Порядок действий по шагам, а не два независимых
                  // поля сразу: сначала создать СВОЙ проект на
                  // Supabase (там же выдаются адрес и ключ), и только
                  // потом возвращаться сюда их вставлять.
                  OutlinedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://supabase.com/dashboard/sign-up'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(tr('1. Создать проект на Supabase')),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('Откроется сайт Supabase — зарегистрируйтесь и создайте новый проект (пустой, без своих таблиц).'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => _copyInstallSql(context),
                    icon: const Icon(Icons.copy_outlined),
                    label: Text(tr('2. Скопировать SQL для настройки базы')),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('В проекте Supabase откройте SQL Editor → New query, вставьте (уже в буфере обмена) и нажмите Run. Один раз, весь текст сразу — создаст все таблицы и покажет строку проверки.'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Text(tr('3. Вставить адрес и ключ'),
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: _url,
                  decoration: InputDecoration(
                    labelText: tr('Адрес базы'),
                    hintText: 'https://xxxx.supabase.co',
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _key,
                  decoration: InputDecoration(
                    labelText: tr('Публичный ключ (anon / publishable)'),
                    hintText: tr('sb_publishable_… или eyJhbGci…'),
                  ),
                  autocorrect: false,
                  obscureText: true,
                ),
                const SizedBox(height: 4),
                Text(
                  tr('Оба значения — в вашем проекте Supabase: Settings → API. Секретный ключ (service_role) сюда вводить не нужно и нельзя.'),
                  style: theme.textTheme.bodySmall,
                ),
              ] else
                TextButton.icon(
                  onPressed: () => setState(() => _showBaseFields = true),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(tr('База: {url}', {'url': _auth.url}),
                      overflow: TextOverflow.ellipsis),
                ),
              const SizedBox(height: 14),
              Text(
                tr('Почта и пароль — это ваш личный вход в эту базу. Адрес базы сам по себе данные не открывает: вход нужен, чтобы вы видели и меняли только свои записи. Это не пароль от Supabase и не пароль мессенджера; при первом входе нажмите «Регистрация».'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _email,
                decoration: InputDecoration(labelText: tr('Почта')),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: tr('Пароль')),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                _saveBase();
                                await _auth.signIn(
                                  email: _email.text,
                                  password: _password.text,
                                );
                                return tr('Вход выполнен');
                              }),
                      child: Text(tr('Войти')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                _saveBase();
                                final immediate = await _auth.signUp(
                                  email: _email.text,
                                  password: _password.text,
                                );
                                // Supabase по умолчанию требует
                                // подтверждения почты и на регистрацию
                                // отвечает без токена. Промолчать
                                // нельзя: человек введёт пароль, ничего
                                // не произойдёт, и виноватым будет
                                // приложение.
                                return immediate
                                    ? tr('Готово, вы вошли')
                                    : tr(
                                        'Аккаунт создан. Подтвердите адрес письмом и войдите — либо отключите подтверждение почты в настройках своего проекта Supabase.');
                              }),
                      child: Text(tr('Зарегистрироваться')),
                    ),
                  ),
                ],
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _messageIsError ? cs.error : cs.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Заголовок "Настройки", который по 7 нажатиям открывает включение/
/// выключение режима разработчика — намеренно не отдельный пункт меню,
/// иначе сам факт его существования был бы на виду у всех (решение
/// пользователя).
class _HiddenDevModeToggle extends StatefulWidget {
  const _HiddenDevModeToggle();

  @override
  State<_HiddenDevModeToggle> createState() => _HiddenDevModeToggleState();
}

class _HiddenDevModeToggleState extends State<_HiddenDevModeToggle> {
  int _taps = 0;

  Future<void> _onTap() async {
    _taps++;
    if (_taps < 7) return;
    _taps = 0;
    final personalization = context.read<PersonalizationViewModel>();

    if (personalization.devMode) {
      final confirmed = await showGlassDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Режим разработчика')),
          content: Text(tr(
              'Выключить? Недоделанные вкладки (Мессенджер, Задания) снова скроются.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(tr('Отмена'))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(tr('Выключить'))),
          ],
        ),
      );
      if (confirmed == true) personalization.disableDevMode();
      return;
    }

    personalization.enableDevMode();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Режим разработчика включён'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: Text(tr('Настройки')),
    );
  }
}


/// Тренер приглашает спортсмена: выбор из контактов мессенджера → тому уходит карточка
/// «Принять / Отказать». Принял — дальше всё автоматически (запрос, согласие, доступ).
Future<void> inviteAthleteViaMessenger(BuildContext context, AppDataStore store) async {
  final msg = ScaffoldMessenger.of(context);
  final auth = ChatAuthService(store.db);
  if (!auth.isSignedIn) {
    msg.showSnackBar(SnackBar(content: Text(tr('Сначала войдите в мессенджер'))));
    return;
  }
  final repo = ChatMessagesRepository(store.db);
  final contacts = [for (final c in repo.listContacts()) if (!c.isGroup) c];
  if (contacts.isEmpty) {
    msg.showSnackBar(SnackBar(content: Text(tr('Добавьте спортсмена в контакты мессенджера, затем повторите'))));
    return;
  }
  final athlete = await showGlassSheet<ChatContact>(
    context: context,
    builder: (ctx) => ListView(children: [
      Padding(padding: const EdgeInsets.all(16), child: Text(tr('Кого пригласить?'), style: Theme.of(ctx).textTheme.titleMedium)),
      for (final c in contacts) ListTile(title: Text(c.nickname), onTap: () => Navigator.pop(ctx, c)),
    ]),
  );
  if (athlete == null || !context.mounted) return;
  if (await auth.friendStatusWith(athlete.id) != 'accepted') {
    if (!context.mounted) return;
    await showGlassDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Сначала добавьте в друзья')),
        content: Text(tr('Приглашение придёт в чат, только если вы друзья в мессенджере. Отправьте заявку в друзья, а когда её примут, повторите.')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Понятно')))],
      ),
    );
    return;
  }
  try {
    await CoachLink(db: store.db, auth: auth, repo: repo, sync: ChatSyncService(auth, repo)).invite(athlete);
    msg.showSnackBar(SnackBar(content: Text(tr('Приглашение отправлено: {c}', {'c': athlete.nickname}))));
  } catch (e) {
    msg.showSnackBar(SnackBar(content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
  }
}

/// «Добавить тренера»: выбор из контактов мессенджера → тренеру уходит запрос
/// (имя, дата рождения, регион). Доступ к данным он получит только после согласия.
Future<void> addCoachViaMessenger(BuildContext context, AppDataStore store) async {
  final msg = ScaffoldMessenger.of(context);
  final auth = ChatAuthService(store.db);
  if (!auth.isSignedIn) {
    msg.showSnackBar(SnackBar(content: Text(tr('Сначала войдите в мессенджер'))));
    return;
  }
  final repo = ChatMessagesRepository(store.db);
  final contacts = [for (final c in repo.listContacts()) if (!c.isGroup) c];
  if (contacts.isEmpty) {
    msg.showSnackBar(SnackBar(content: Text(tr('Добавьте тренера в контакты мессенджера, затем повторите'))));
    return;
  }
  final coach = await showGlassSheet<ChatContact>(
    context: context,
    builder: (ctx) => ListView(children: [
      Padding(padding: const EdgeInsets.all(16), child: Text(tr('Кто ваш тренер?'), style: Theme.of(ctx).textTheme.titleMedium)),
      for (final c in contacts) ListTile(title: Text(c.nickname), onTap: () => Navigator.pop(ctx, c)),
    ]),
  );
  if (coach == null || !context.mounted) return;
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Отправить запрос тренеру?')),
      content: Text(tr('{c} получит ваше имя, дату рождения и регион из профиля. Доступ к вашим данным он получит только после своего согласия.', {'c': coach.nickname})),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Отправить'))),
      ],
    ),
  );
  if (ok != true) return;
  // При приватности «только друзья» сообщение незнакомого не попадает в чат
  // (приходит только уведомление), поэтому запрос просим отправлять друзьям.
  if (await auth.friendStatusWith(coach.id) != 'accepted') {
    if (!context.mounted) return;
    await showGlassDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Сначала добавьте в друзья')),
        content: Text(tr('Запрос придёт тренеру в чат только если вы друзья в мессенджере. Отправьте ему заявку в друзья, а когда он её примет, повторите.')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Понятно')))],
      ),
    );
    return;
  }
  try {
    final sync = ChatSyncService(auth, repo);
    await CoachLink(db: store.db, auth: auth, repo: repo, sync: sync).requestCoach(coach);
    msg.showSnackBar(SnackBar(content: Text(tr('Запрос отправлен: {c}', {'c': coach.nickname}))));
  } catch (e) {
    msg.showSnackBar(SnackBar(content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
  }
}
