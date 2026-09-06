import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import '../widgets/section_header.dart';
import 'import_screen.dart';
import 'ai_settings_screen.dart';
import 'color_personalization_screen.dart';

/// Настройки (раздел 9 ТЗ).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _syncing = false;
  String? _syncMessage;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final bothRoles = store.isAthlete && store.isCoach;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionHeader(
              title: 'Оформление',
              subtitle: 'Тема интерфейса. Цвета самой мишени настраиваются отдельно.',
            ),
          ),
          const _ThemeModeSelector(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Персонализация цвета мишени'),
            subtitle: const Text('Бумага, яблоко, кольца, пробоины'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ColorPersonalizationScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Ассистент по результатам'),
            subtitle: const Text('Ключ OpenRouter, модели, справочные материалы'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Импорт тренировок'),
            subtitle: const Text('Из файла: координаты, результаты, показатели прибора'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ImportScreen()),
            ),
          ),
          const Divider(height: 24),
          if (bothRoles)
            SwitchListTile(
              title: const Text('Режим работы: тренер'),
              subtitle: Text(store.workMode == WorkMode.coach ? 'Тренер' : 'Спортсмен'),
              value: store.workMode == WorkMode.coach,
              onChanged: (v) {
                store.workMode = v ? WorkMode.coach : WorkMode.athlete;
                store.saveSettings();
                setState(() {});
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SectionHeader(
              title: 'Хранение',
              subtitle: 'Что держать на устройстве, а что только в облаке',
            ),
          ),
          // Три состояния вместо одного ползунка: «только облако»,
          // «последние N» и «всё на устройстве». Ползунок сам по себе
          // не отвечал на главный вопрос — держать ли данные локально
          // вообще.
          SwitchListTile(
            title: const Text('Хранить только в облаке'),
            subtitle: const Text('На устройстве не остаётся ничего'),
            value: store.storageKeepCount == 0,
            onChanged: (v) {
              store.storageKeepCount = v ? 0 : 200;
              store.saveSettings();
              setState(() {});
            },
          ),
          if (store.storageKeepCount != 0) ...[
            SwitchListTile(
              title: const Text('Хранить всё на устройстве'),
              subtitle: const Text('Ничего не вытесняется'),
              value: store.storageKeepCount >= AppDataStore.keepAll,
              onChanged: (v) {
                store.storageKeepCount = v ? AppDataStore.keepAll : 200;
                store.saveSettings();
                setState(() {});
              },
            ),
            if (store.storageKeepCount < AppDataStore.keepAll)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextFormField(
                  initialValue: '${store.storageKeepCount}',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Сколько тренировок держать на устройстве',
                    helperText: 'Остальные — только в облаке',
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n == null || n <= 0) return;
                    store.storageKeepCount = n;
                    store.saveSettings();
                  },
                ),
              ),
          ],
          const Divider(height: 24),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SectionHeader(
              title: 'Синхронизация',
              subtitle: 'Облако — резервная копия. Без автоматики, без «только Wi-Fi».',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _syncing ? null : () => _syncNow(context),
                  icon: _syncing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Синхронизировать сейчас'),
                ),
                if (_syncMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_syncMessage!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          const _ShareTokensSection(),
          const Divider(height: 24),
          // Учётная запись — в самом низу, как просил пользователь:
          // заходят сюда раз в жизни, а место наверху занимает то, что
          // трогают каждый день.
          const _AccountTile(),
        ],
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final store = context.read<AppDataStore>();
    final sync = SupabaseSyncService(SupabaseAuthService(store.db));
    try {
      final pushed = await sync.push(store);
      final result = await sync.pull(store);
      final parts = <String>[];
      if (pushed > 0) parts.add('отправлено: $pushed');
      if (result.pulledSessions > 0) parts.add('получено тренировок: ${result.pulledSessions}');
      if (result.pulledExercises > 0) parts.add('упражнений: ${result.pulledExercises}');
      if (result.pulledComments > 0) parts.add('комментариев: ${result.pulledComments}');
      setState(() => _syncMessage = parts.isEmpty ? 'Готово, новых данных не было' : 'Готово — ${parts.join(', ')}');
    } catch (e) {
      setState(() => _syncMessage = '$e');
    } finally {
      setState(() => _syncing = false);
    }
  }
}

/// Переключатель светлой/тёмной темы интерфейса.
///
/// Значение живёт в `PersonalizationViewModel` (та же key-value таблица
/// `color_prefs`), поэтому переживает перезапуск. "Система" — значение
/// по умолчанию: приложение следует настройке ОС.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('Система'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Светлая'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Тёмная'),
            ),
          ],
          selected: {vm.themeMode},
          showSelectedIcon: false,
          onSelectionChanged: (set) => vm.setThemeMode(set.first),
        ),
      ),
    );
  }
}

class _ShareTokensSection extends StatefulWidget {
  const _ShareTokensSection();

  @override
  State<_ShareTokensSection> createState() => _ShareTokensSectionState();
}

class _ShareTokensSectionState extends State<_ShareTokensSection> {
  String? _lastCreatedToken;
  bool _busy = false;
  String? _error;

  late final SupabaseAuthService _auth;
  late final SupabaseSyncService _sync;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppDataStore>();
    _auth = SupabaseAuthService(store.db);
    _sync = SupabaseSyncService(_auth);
    // Список токенов на сервере — источник истины (отозвать можно и с
    // другого устройства), поэтому подтягиваем его при открытии
    // экрана, а не полагаемся на то, что осело в локальной базе.
    if (_auth.isSignedIn) _refresh();
  }

  Future<void> _refresh() async {
    try {
      await _sync.refreshShareGrants(context.read<AppDataStore>());
    } catch (_) {
      // Не удалось обновить список — покажем то, что уже есть локально;
      // отдельно сообщать об ошибке здесь не за что: пользователь ничего
      // не запрашивал явно.
    }
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await _sync.createShareToken(context.read<AppDataStore>());
      if (!mounted) return;
      setState(() => _lastCreatedToken = token);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(String grantId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sync.revokeShareToken(context.read<AppDataStore>(), grantId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final signedIn = _auth.isSignedIn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SectionHeader(
            title: 'Доступ тренерам',
            subtitle: 'Токены на просмотр вашего дневника',
          ),
        ),
        if (!signedIn)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              // Токен без базы работать не может — тренеру попросту
              // некуда его подставить, поэтому честнее не предлагать
              // создать его локально "про запас".
              'Сначала войдите в базу Supabase — токен проверяется на сервере, '
              'без неё выдавать его некому.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_lastCreatedToken != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              // Предупреждающая карточка: янтарный контейнер темы вместо
              // прежнего хардкода Colors.amber.shade50, который в тёмной
              // теме давал светлую плашку со светлым текстом.
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: Theme.of(context).colorScheme.onSecondaryContainer),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Токен показывается только один раз',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _lastCreatedToken!,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ...store.shareGrants.map((g) => ListTile(
              title: Text(g.athleteLabel.isEmpty ? 'Токен ${g.id.substring(0, 6)}' : g.athleteLabel),
              subtitle: Text('Создан ${g.createdAt.toLocal()}'),
              trailing: TextButton(
                onPressed: _busy ? null : () => _revoke(g.id),
                child: const Text('Отозвать'),
              ),
            )),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            label: const Text('Создать токен'),
            onPressed: (!signedIn || _busy) ? null : _create,
          ),
        ),
      ],
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
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Учётная запись', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Приложение подключается к вашей собственной базе Supabase. '
              'Учётная запись создаётся в ней же — отдельной регистрации '
              'где-то ещё не нужно.',
              style: theme.textTheme.bodySmall,
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
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        _auth.signOutLocally();
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
