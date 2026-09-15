import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/home_tab_specs.dart';
import '../services/ai_settings.dart';
import '../services/knowledge_column_discovery.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import 'ai_settings_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_data_screen.dart';
import 'settings_home_tabs_screen.dart';

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

  const SettingsScreen({super.key, required this.homeTabs});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
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
            subtitle: const Text('Ключ OpenRouter, модели, справочные материалы'),
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
              MaterialPageRoute(builder: (_) => SettingsHomeTabsScreen(specs: homeTabSpecs, tabs: homeTabs)),
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
    if (!mounted) return;
    setState(() => _message = 'Таблицы для ИИ обновлены');
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
                    'проект. Затем вернитесь сюда и вставьте адрес и ключ из '
                    'Settings → API этого проекта.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Text('2. Вставить адрес и ключ', style: theme.textTheme.labelLarge),
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
