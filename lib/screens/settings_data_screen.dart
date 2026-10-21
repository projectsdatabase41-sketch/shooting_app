import '../services/modules_settings.dart';
import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import '../logic/friendly_error.dart';
import 'db_check_screen.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_sync_service.dart';
import '../services/coach_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/section_header.dart';
import 'export_screen.dart';
import 'settings_screen.dart' show AccountTile, addCoachViaMessenger;
import '../i18n/i18n.dart';

/// "Данные и синхронизация" — импорт/экспорт, ручная синхронизация с
/// облаком и токены доступа тренерам, вынесены из общего списка настроек
/// в отдельную папку (решение пользователя: распределить настройки по
/// назначению вместо одного длинного списка).
class SettingsDataScreen extends StatefulWidget {
  const SettingsDataScreen({super.key});

  @override
  State<SettingsDataScreen> createState() => _SettingsDataScreenState();
}

class _SettingsDataScreenState extends State<SettingsDataScreen> {
  bool _syncing = false;
  String? _syncMessage;
  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();

    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Данные и синхронизация'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: AppBackdrop(kind: 'settings', child: ListView(
        padding: EdgeInsets.fromLTRB(0, topInset + GlassHeader.height, 0, 32),
        children: [
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: Text(tr('Импорт тренировок')),
            subtitle: Text(tr('Загрузка тренировок из других источников')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showImportDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: Text(tr('Проверка базы')),
            subtitle: Text(tr('Всё ли создано в вашей базе')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DbCheckScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: Text(tr('Экспорт тренировок')),
            subtitle: Text(tr('Резервная копия в файл')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ExportScreen()),
            ),
          ),
          const Divider(height: 24),
          // Подключение своей базы Supabase — здесь же, где синхронизация.
          const AccountTile(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SectionHeader(title: tr('Синхронизация')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Разделено на "из" и "в" (решение пользователя): раньше
                // одна кнопка делала оба разом, и новую тренировку на
                // телефоне нельзя было ТОЛЬКО подтянуть с сервера, не
                // отправив заодно локальные.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _syncing ? null : () => _pullNow(context),
                      icon: _syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download_outlined),
                      label: Text(tr('Загрузить из облака')),
                    ),
                    FilledButton.icon(
                      onPressed: _syncing ? null : () => _pushNow(context),
                      icon: _syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_upload_outlined),
                      label: Text(tr('Отправить в облако')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // На случай, когда "Загрузить из облака" пишет "ничего
                // нового", а списки на телефоне пустые — обычно значит,
                // что нужные записи локально помечены удалёнными/скрытыми
                // и из-за этого не считаются новыми при обычной сверке.
                // Снимает эти отметки и подтягивает всё, чего не хватает.
                TextButton.icon(
                  onPressed: _syncing ? null : () => _forceRecover(context),
                  icon: const Icon(Icons.restore_outlined),
                  label: Text(tr('Восстановить всё из облака')),
                ),
                if (_syncMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_syncMessage!,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          // Тренер не ведёт свои тренировки и никому не передаёт свои
          // данные — токен доступа тренерам нужен только спортсмену.
          if (store.isAthlete) ...[
            const Divider(height: 24),
            const ShareTokensSection(),
          ],
        ],
      )),
    );
  }

  Future<void> _pullNow(BuildContext context) async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final store = context.read<AppDataStore>();
    final sync = SupabaseSyncService(SupabaseAuthService(store.db));
    try {
      final result = await sync.pull(store);
      final parts = <String>[];
      if (result.pulledSessions > 0)
        parts.add(tr('получено тренировок: {pulledSessions}',
            {'pulledSessions': result.pulledSessions}));
      if (result.pulledExercises > 0)
        parts.add(tr('упражнений: {pulledExercises}',
            {'pulledExercises': result.pulledExercises}));
      if (result.pulledComments > 0)
        parts.add(tr('комментариев: {pulledComments}',
            {'pulledComments': result.pulledComments}));
      setState(() => _syncMessage = parts.isEmpty
          ? tr('Готово, новых данных не было')
          : tr('Готово — {p}', {'p': parts.join(', ')}));
    } catch (e) {
      setState(() => _syncMessage = friendlyError(e));
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _forceRecover(BuildContext context) async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final store = context.read<AppDataStore>();
    store.clearLocalTombstones();
    final sync = SupabaseSyncService(SupabaseAuthService(store.db));
    try {
      final result = await sync.pull(store);
      final parts = <String>[];
      if (result.pulledSessions > 0)
        parts.add(tr('получено тренировок: {pulledSessions}',
            {'pulledSessions': result.pulledSessions}));
      if (result.pulledExercises > 0)
        parts.add(tr('упражнений: {pulledExercises}',
            {'pulledExercises': result.pulledExercises}));
      if (result.pulledComments > 0)
        parts.add(tr('комментариев: {pulledComments}',
            {'pulledComments': result.pulledComments}));
      setState(() => _syncMessage = parts.isEmpty
          ? tr('Готово, новых данных не было')
          : tr('Готово — {p}', {'p': parts.join(', ')}));
    } catch (e) {
      setState(() => _syncMessage = friendlyError(e));
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _pushNow(BuildContext context) async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final store = context.read<AppDataStore>();
    final sync = SupabaseSyncService(SupabaseAuthService(store.db));
    try {
      final deleted = await sync.pushDeletions(store);
      final pushed = await sync.push(store);
      final parts = <String>[];
      if (deleted > 0)
        parts.add(tr('удалено: {deleted}', {'deleted': deleted}));
      if (pushed > 0) parts.add(tr('отправлено: {pushed}', {'pushed': pushed}));
      setState(() => _syncMessage = parts.isEmpty
          ? tr('Готово, новых данных не было')
          : tr('Готово — {p}', {'p': parts.join(', ')}));
    } catch (e) {
      setState(() => _syncMessage = friendlyError(e));
    } finally {
      setState(() => _syncing = false);
    }
  }
}

/// Импорт тренировок пока не встроен в приложение — вместо этого
/// открываем чат с ИИ-ассистентом, где пользователь может выгрузить
/// свою переписку/данные и попросить помочь перенести их (решение
/// пользователя). Каждая кнопка — ссылка на веб-чат сервиса; на
/// телефоне с установленным приложением ОС сама предложит открыть его
/// вместо браузера.
void _showImportDialog(BuildContext context) {
  const links = {
    'ChatGPT': 'https://chat.openai.com',
    'Claude': 'https://claude.ai',
    'Qwen': 'https://chat.qwen.ai',
  };
  showGlassDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Импорт через ИИ-ассистента')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in links.entries) ...[
            OutlinedButton(
              onPressed: () => launchUrl(Uri.parse(entry.value),
                  mode: LaunchMode.externalApplication),
              child: Text(entry.key),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Text(
            tr('Импорт внутри самого приложения пока в разработке.'),
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('Закрыть'))),
      ],
    ),
  );
}

class ShareTokensSection extends StatefulWidget {
  const ShareTokensSection({super.key});

  @override
  State<ShareTokensSection> createState() => _ShareTokensSectionState();
}

class _ShareTokensSectionState extends State<ShareTokensSection> {
  String? _lastCreatedToken;
  bool _busy = false;
  String? _error;

  late final SupabaseAuthService _auth;
  late final SupabaseSyncService _sync;

  /// Тренеры из мессенджера: приняли запрос, но доступ ещё не выдан.
  List<({String clientId, String name, String state})> _pending = const [];

  CoachLink _link(AppDataStore store) {
    final chatAuth = ChatAuthService(store.db);
    final repo = ChatMessagesRepository(store.db);
    return CoachLink(db: store.db, auth: chatAuth, repo: repo, sync: ChatSyncService(chatAuth, repo));
  }

  void _loadPending() {
    try {
      _pending = _link(context.read<AppDataStore>()).pendingGrants();
    } catch (_) {
      _pending = const [];
    }
  }

  Future<void> _grantNow() async {
    final store = context.read<AppDataStore>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = await _link(store).processIncoming(store);
      await _refresh();
      if (!mounted) return;
      if (n == 0) {
        setState(() => _error = tr('Доступ не выдан: войдите в свою базу (Настройки → Данные и синхронизация → Учётная запись) и повторите'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) {
        _loadPending();
        setState(() => _busy = false);
      }
    }
  }

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
    _loadPending();
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

  /// Имя токена и политика доступа: «Базовый» — тренировки, результаты,
  /// комментарии; «Расширенный» — плюс таблицы на выбор из личной базы.
  /// Пустое имя — тоже валидный ответ, просто без подписи.
  Future<({String label, String policy, List<String> tables})?>
      _askTokenSettings() async {
    final controller = TextEditingController();
    var extended = false;
    final selected = <String>{};
    List<String>? available;
    String? tablesError;
    final db = context.read<AppDataStore>().db;
    // Не предлагаем: служебные таблицы и таблицы самого приложения — тренировки,
    // результаты, комментарии, задания и т.п. тренер и так видит на базовом уровне.
    // В расширенном выбираются только ДОПОЛНИТЕЛЬНЫЕ таблицы вашей базы.
    const blocked = {
      'share_grants',
      'share_events',
      'project_settings',
      'chat_push_tokens',
      'task_devices',
      'keepalive_log',
      'table_docs',
      'training_packages',
      'shots',
      'exercises',
      'exercise_templates',
      'target_faces',
      'comments',
      'training_notes',
      'archived_packages',
      'file_assets',
      'photo_import_jobs',
      'remote_athlete_sources',
      'ai_conversation_summaries',
      'tasks',
      'task_stages',
      'task_steps',
      'task_clarifications',
      'task_runs',
      'task_run_steps',
      'task_shots',
      'task_reports',
      'task_events',
      'task_series_notes',
    };

    return showGlassDialog<({String label, String policy, List<String> tables})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> loadTables() async {
            try {
              final names = await SupabaseAuthService(db).fetchTableNames();
              setLocal(() => available = [
                    for (final n in names)
                      if (!blocked.contains(n)) n
                  ]);
            } catch (e) {
              setLocal(() => tablesError = friendlyError(e));
            }
          }

          return AlertDialog(
            title: Text(tr('Название токена')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: tr('Имя, кому предназначен'),
                      hintText: tr('например «Тренер Иванов»'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(tr('Что увидит тренер'),
                      style: Theme.of(ctx).textTheme.labelMedium),
                  const SizedBox(height: 6),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(tr('Базовый'))),
                      ButtonSegment(
                          value: true, label: Text(tr('Расширенный'))),
                    ],
                    selected: {extended},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) {
                      setLocal(() => extended = v.first);
                      if (extended && available == null && tablesError == null)
                        loadTables();
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    extended
                        ? tr(
                            'Тренировки, результаты, комментарии и выбранные ниже таблицы.')
                        : tr(
                            'Только тренировки, результаты и комментарии к ним.'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  if (extended) ...[
                    const SizedBox(height: 10),
                    if (tablesError != null)
                      Text(tablesError!,
                          style:
                              TextStyle(color: Theme.of(ctx).colorScheme.error))
                    else if (available == null)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator()))
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in available!)
                            FilterChip(
                              label: Text(t),
                              selected: selected.contains(t),
                              onSelected: (v) => setLocal(() =>
                                  v ? selected.add(t) : selected.remove(t)),
                            ),
                        ],
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(tr('Отмена'))),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop((
                  label: controller.text.trim(),
                  policy: extended ? 'extended' : 'basic',
                  tables: selected.toList()..sort(),
                )),
                child: Text(tr('Создать')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _create() async {
    final settings = await _askTokenSettings();
    if (settings == null) return; // отменили в диалоге
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await _sync.createShareToken(context.read<AppDataStore>(),
          athleteLabel: settings.label,
          policy: settings.policy,
          tables: settings.tables);
      if (!mounted) return;
      setState(() => _lastCreatedToken = token);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
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
      setState(() => _error = friendlyError(e));
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SectionHeader(
            title: tr('Доступ тренерам'),
            subtitle: tr('Токены на просмотр ваших тренировок'),
          ),
        ),
        if (!signedIn)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              // Токен без базы работать не может — тренеру попросту
              // некуда его подставить, поэтому честнее не предлагать
              // создать его локально "про запас".
              tr('Сначала войдите в базу Supabase — токен проверяется на сервере, без неё выдавать его некому.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
                            size: 16,
                            color: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            tr('Токен показывается только один раз'),
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Сам токен на экран не выводим — только кнопка
                    // копирования (решение пользователя): скопировать и
                    // сразу отправить тренеру, глазами читать незачем,
                    // а плечом подсмотреть — риск.
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: _lastCreatedToken!));
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                              SnackBar(content: Text(tr('Токен скопирован'))));
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: Text(tr('Скопировать токен')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (ModulesSettings.isOn(store.db, AppModule.messenger))
        ListTile(
          leading: const Icon(Icons.how_to_reg_outlined),
          title: Text(tr('Добавить тренера')),
          subtitle: Text(tr('Подключение тренера через мессенджер')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => addCoachViaMessenger(context, store),
        ),
        for (final p in _pending)
          ListTile(
            leading: const Icon(Icons.hourglass_top),
            title: Text(p.name),
            subtitle: Text(tr('Принял запрос, доступ не выдан')),
            trailing: TextButton(
              onPressed: _busy ? null : _grantNow,
              child: Text(tr('Выдать')),
            ),
          ),
        ...store.shareGrants.map((g) => ListTile(
              title: Text(g.athleteLabel.isEmpty
                  ? tr('Токен {p}', {'p': g.id.substring(0, 6)})
                  : g.athleteLabel),
              subtitle: Text([
                tr('Создан {p}', {'p': g.createdAt.toLocal()}),
                g.isExtended
                    ? tr('Расширенный: {t}',
                        {'t': g.tables.isEmpty ? '—' : g.tables.join(', ')})
                    : tr('Базовый'),
              ].join('\n')),
              isThreeLine: g.isExtended,
              trailing: TextButton(
                onPressed: _busy ? null : () => _revoke(g.id),
                child: Text(tr('Отозвать')),
              ),
            )),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            label: Text(tr('Создать токен')),
            onPressed: (!signedIn || _busy) ? null : _create,
          ),
        ),
      ],
    );
  }
}
