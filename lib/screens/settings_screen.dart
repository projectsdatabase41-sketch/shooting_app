import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/home_tab_specs.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/custom_services_repository.dart';
import '../services/knowledge_column_discovery.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../state/personalization_view_model.dart';
import '../widgets/home_tabs_bar.dart';
import '../widgets/service_icon_picker.dart';
import 'ai_settings_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_data_screen.dart';
import 'settings_home_tabs_screen.dart';
import 'settings_services_screen.dart';

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

  const SettingsScreen({super.key, required this.homeTabs, required this.services});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final specs = <String, HomeTabSpec>{
      ...homeTabSpecs,
      for (final s in services.list())
        '$serviceTabPrefix${s.id}': HomeTabSpec(icon: iconForService(s.iconName), label: s.name),
    };

    return Scaffold(
      appBar: AppBar(title: const _HiddenDevModeToggle()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Внешний вид'),
            subtitle: const Text('Язык, цвета и тема интерфейса'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsAppearanceScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('ИИ Ассистент'),
            subtitle: const Text('Облачный ИИ, свой API Key, модели'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Данные и синхронизация'),
            subtitle: const Text('Импорт, экспорт, облако, доступ тренерам'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsDataScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Рабочие пространства'),
            subtitle: const Text('Какие вкладки показывать на главном экране и в каком порядке'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsHomeTabsScreen(specs: specs, tabs: homeTabs)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Сервисы'),
            subtitle: const Text('Google Диск, Supabase, заметки и другие свои плитки'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsServicesScreen(repo: services)),
            ),
          ),
          const Divider(height: 24),
          // Рубильник, а не переключатель режима внутри уже включённой
          // тренерской роли: раньше эту роль вообще не было видно как
          // включить — переключатель показывался, только если isCoach
          // уже почему-то стоял true, а поставить его true было неоткуда.
          // По умолчанию — всегда спортсмен; включили — стали тренером,
          // это единственная и исключающая пара, не два флага сразу.
          SwitchListTile(
            title: const Text('Режим тренера'),
            subtitle: Text(
              store.workMode == WorkMode.coach
                  ? 'Тренер — свои тренировки не ведёте, только дневники подключённых спортсменов'
                  : 'Спортсмен — обычный режим',
            ),
            value: store.workMode == WorkMode.coach,
            onChanged: (v) {
              // Не устанавливаем store.workMode отдельно: при ровно
              // одной активной роли (а здесь всегда так) геттер сам
              // выводит режим из isAthlete/isCoach.
              store.isCoach = v;
              store.isAthlete = !v;
              store.saveSettings();
              // notifyListeners() (тот же AppDataStore, который слушает
              // HomeShell через context.watch) сам перерисует нижнюю
              // навигацию — здесь достаточно просто сохранить.
              store.refreshView();
            },
          ),
          const Divider(height: 24),
          // Учётная запись — в самом низу, как просил пользователь:
          // заходят сюда раз в жизни, а место наверху занимает то, что
          // трогают каждый день.
          const _AccountTile(),
        ],
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
class _AccountTile extends StatelessWidget {
  const _AccountTile();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final auth = SupabaseAuthService(store.db);
    final signedIn = auth.isSignedIn;

    return ListTile(
      leading: Icon(signedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
      title: const Text('Учётная запись'),
      subtitle: Text(
        signedIn
            ? auth.email
            : auth.hasBase
                ? 'База указана, вход не выполнен'
                : 'Своя база Supabase не подключена',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showModalBottomSheet<void>(
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
      final sql = await rootBundle.loadString('lib/db/puls_install.sql');
      await Clipboard.setData(ClipboardData(text: sql));
      message = 'SQL скопирован — вставьте в SQL Editor Supabase и нажмите Run';
    } catch (e) {
      // Браузер иногда отказывает в доступе к буферу обмена (нет разрешения,
      // окно не в фокусе) — тогда честно сказать об этом, а не падать молча.
      message = 'Не удалось скопировать: $e';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final ok = await action();
      if (!mounted) return;
      // "Учётная запись" на самом экране настроек (_AccountTile) читает
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
        _message = '$e';
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
        _message = '$e';
        _messageIsError = true;
      });
      return;
    }
    if (!context.mounted) return;
    final settings = AiSettings(context.read<AppDataStore>().db);
    final existing = {for (final t in settings.tables) t.name: t};
    final selected = {for (final n in names) n: existing.containsKey(n)};

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Таблицы для ИИ'),
          content: SizedBox(
            width: double.maxFinite,
            child: names.isEmpty
                ? const Text('В базе не нашлось таблиц, кроме тех, что уже использует само приложение.')
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final n in names)
                          CheckboxListTile(
                            value: selected[n],
                            title: Text(n),
                            onChanged: (v) => setDialogState(() => selected[n] = v ?? false),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Сохранить')),
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
      content: Text(chosen.isEmpty ? 'Таблицы для ИИ отключены' : 'ИИ теперь видит: $chosen'),
    ));

    // Понять, что за таблицу подключили: без описания ИИ видит только
    // имя таблицы и колонки, но не знает, дневник это или что-то ещё
    // (пункт: "при добавлении новой базы... ИИ сам запрашивает структуру
    // базы... сохраняет во внутреннюю память, что это за база"). Пустую
    // таблицу описываем только по структуре — само содержание опишется
    // при следующем открытии этого экрана, когда данные уже появятся.
    final needsDescription =
        settings.tables.where((t) => t.description.isEmpty || t.description == _emptyTableNote).toList();
    // Описание — в фоне: лист уже закрыт, результат просто сохранится.
    if (needsDescription.isNotEmpty) _describeTables(settings, needsDescription);
  }

  static const _emptyTableNote = 'Таблица пока пустая, содержимого ещё нет.';

  Future<String?> _describeTables(AiSettings settings, List<KnowledgeTableConfig> tables) async {
    final token = await _auth.ensureFreshToken() ?? _auth.anonKey;
    final baseUrl = '${_auth.url}/rest/v1';
    final aiService = AiService(settings);
    final updated = {for (final t in settings.tables) t.name: t};
    for (final t in tables) {
      final desc = await _describeOneTable(t, baseUrl, token, aiService);
      if (desc != null) {
        updated[t.name] = KnowledgeTableConfig(name: t.name, label: t.label, description: desc, contentColumn: t.contentColumn);
      }
    }
    settings.tables = updated.values.toList();
    return 'Таблицы для ИИ обновлены';
  }

  Future<String?> _describeOneTable(
    KnowledgeTableConfig t,
    String baseUrl,
    String token,
    AiService aiService,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/${t.name}').replace(queryParameters: {'select': '*', 'limit': '3'});
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
        systemPrompt: 'Ты помогаешь приложению для стрельбы понять смысл ЧУЖОЙ таблицы базы данных, '
            'которую подключил пользователь. Дан список колонок и примеры строк. Опиши ОДНИМ коротким '
            'предложением, что это за таблица и как её содержимое использовать при ответах пользователю. '
            'Без markdown, без кавычек, только суть.',
        contextBlock: 'Таблица "${t.name}". Колонки: ${firstRow.keys.join(", ")}. '
            'Примеры строк: ${jsonEncode(rows.take(2).toList())}',
        history: const [(role: 'user', text: 'Что это за таблица?')],
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
        padding: EdgeInsets.only(bottom: kIsWeb ? 0 : MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Учётная запись', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Подключение к Supabase', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://supabase.com/dashboard/sign-up'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Регистрация в Supabase'),
            ),
            const SizedBox(height: 16),

            if (signedIn) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(_auth.email.isEmpty ? 'Вход выполнен' : _auth.email),
                subtitle: Text(_auth.url, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(_auth.checkSchema),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Проверить базу'),
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
                label: const Text('Таблицы для ИИ'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        _auth.signOutLocally();
                        context.read<AppDataStore>().refreshView();
                        setState(() => _message = 'Вы вышли. Тренировки на устройстве остались на месте.');
                      },
                icon: const Icon(Icons.logout),
                label: const Text('Выйти'),
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
                          _message = 'База отключена';
                        });
                      },
                icon: Icon(Icons.link_off, color: cs.error),
                label: Text('Отключить базу', style: TextStyle(color: cs.error)),
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
                    label: const Text('1. Создать проект на Supabase'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Откроется сайт Supabase — зарегистрируйтесь и создайте новый '
                    'проект (пустой, без своих таблиц).',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => _copyInstallSql(context),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('2. Скопировать SQL для настройки базы'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'В проекте Supabase откройте SQL Editor → New query, вставьте '
                    '(уже в буфере обмена) и нажмите Run. Один раз, весь текст сразу — '
                    'создаст все таблицы и покажет строку проверки.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Text('3. Вставить адрес и ключ', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Адрес базы',
                    hintText: 'https://xxxx.supabase.co',
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _key,
                  decoration: const InputDecoration(
                    labelText: 'Публичный ключ (anon / publishable)',
                    hintText: 'sb_publishable_… или eyJhbGci…',
                  ),
                  autocorrect: false,
                  obscureText: true,
                ),
                const SizedBox(height: 4),
                Text(
                  'Оба значения — в вашем проекте Supabase: Settings → API. '
                  'Секретный ключ (service_role) сюда вводить не нужно и нельзя.',
                  style: theme.textTheme.bodySmall,
                ),
              ] else
                TextButton.icon(
                  onPressed: () => setState(() => _showBaseFields = true),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text('База: ${_auth.url}', overflow: TextOverflow.ellipsis),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Почта'),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Пароль'),
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
                                return 'Вход выполнен';
                              }),
                      child: const Text('Войти'),
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
                                    ? 'Готово, вы вошли'
                                    : 'Аккаунт создан. Подтвердите адрес письмом '
                                        'и войдите — либо отключите подтверждение '
                                        'почты в настройках своего проекта Supabase.';
                              }),
                      child: const Text('Зарегистрироваться'),
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
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Режим разработчика'),
          content: const Text('Выключить? Недоделанные вкладки (Мессенджер, Задания) снова скроются.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Выключить')),
          ],
        ),
      );
      if (confirmed == true) personalization.disableDevMode();
      return;
    }

    final ctrl = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Режим разработчика'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
          decoration: const InputDecoration(labelText: 'Пароль'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Включить')),
        ],
      ),
    );
    if (password == null || !mounted) return;
    final ok = personalization.tryEnableDevMode(password);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Режим разработчика включён' : 'Неверный пароль')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: const Text('Настройки'),
    );
  }
}
