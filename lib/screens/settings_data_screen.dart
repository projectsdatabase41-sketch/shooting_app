import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../widgets/section_header.dart';
import 'export_screen.dart';

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

    return Scaffold(
      appBar: AppBar(title: const Text('Данные и синхронизация')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Импорт тренировок'),
            subtitle: const Text('Через чат с ИИ-ассистентом'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showImportDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: const Text('Экспорт тренировок'),
            subtitle: const Text('В файл: для резервной копии или переноса на другое устройство'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ExportScreen()),
            ),
          ),
          const Divider(height: 24),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SectionHeader(title: 'Синхронизация'),
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
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download_outlined),
                      label: const Text('Загрузить из облака'),
                    ),
                    FilledButton.icon(
                      onPressed: _syncing ? null : () => _pushNow(context),
                      icon: _syncing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Отправить в облако'),
                    ),
                  ],
                ),
                if (_syncMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_syncMessage!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          // Тренер не ведёт свои тренировки и никому не передаёт свои
          // данные — токен доступа тренерам нужен только спортсмену.
          if (store.workMode != WorkMode.coach) ...[
            const Divider(height: 24),
            const ShareTokensSection(),
          ],
        ],
      ),
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
      if (deleted > 0) parts.add('удалено: $deleted');
      if (pushed > 0) parts.add('отправлено: $pushed');
      setState(() => _syncMessage = parts.isEmpty ? 'Готово, новых данных не было' : 'Готово — ${parts.join(', ')}');
    } catch (e) {
      setState(() => _syncMessage = '$e');
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
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Импорт через ИИ-ассистента'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in links.entries) ...[
            OutlinedButton(
              onPressed: () => launchUrl(Uri.parse(entry.value), mode: LaunchMode.externalApplication),
              child: Text(entry.key),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Text(
            'Импорт внутри самого приложения пока в разработке.',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Закрыть')),
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

  /// Спрашивает, кому предназначен токен, ДО создания — само поле уже
  /// давно поддержано на сервере (`athleteLabel`/`share_grants.label`),
  /// не хватало только запроса имени в интерфейсе (пункт 13 списка
  /// правок). Пустое имя — тоже валидный ответ, просто без подписи.
  Future<String?> _askTokenLabel() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название токена'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Имя, кому предназначен',
            hintText: 'например «Тренер Иванов»',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final label = await _askTokenLabel();
    if (label == null) return; // отменили в диалоге
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await _sync.createShareToken(context.read<AppDataStore>(), athleteLabel: label);
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
                    // Сам токен на экран не выводим — только кнопка
                    // копирования (решение пользователя): скопировать и
                    // сразу отправить тренеру, глазами читать незачем,
                    // а плечом подсмотреть — риск.
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _lastCreatedToken!));
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(const SnackBar(content: Text('Токен скопирован')));
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Скопировать токен'),
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
