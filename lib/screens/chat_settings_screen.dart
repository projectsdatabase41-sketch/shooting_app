import 'package:flutter/material.dart';

import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/chat_translation_service.dart';
import '../services/local_db_service.dart';
import 'chat_appearance_screen.dart';
import 'chat_privacy_screen.dart';
import '../i18n/i18n.dart';

/// Настройки мессенджера — разделами-папками (решение пользователя):
/// язык и перевод, оформление, уведомления, приватность, аккаунт.
class ChatSettingsScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;
  final LocalDbService db;
  final VoidCallback onChanged;

  const ChatSettingsScreen({
    super.key,
    required this.auth,
    required this.repo,
    required this.sync,
    required this.prefs,
    required this.db,
    required this.onChanged,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.prefs;
    final auth = widget.auth;
    final lang = chatLanguageLabel(prefs.translationLanguage);
    Widget folder(IconData icon, String title, String subtitle, Widget page) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(page),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Настройки'))),
      body: ListView(
        children: [
          folder(
            Icons.translate_outlined,
            tr('Язык и перевод'),
            tr('{lang} · автоперевод {p}', {'lang': lang, 'p': prefs.autoTranslate ? tr('во всех чатах') : tr('по выбору в чате')}),
            ChatTranslationSettingsScreen(prefs: prefs),
          ),
          folder(
            Icons.palette_outlined,
            tr('Персонализация'),
            tr('Цвета, шрифт, форма сообщений, фон'),
            ChatAppearanceScreen(prefs: prefs, db: widget.db),
          ),
          folder(
            Icons.notifications_outlined,
            tr('Уведомления'),
            auth.personalPushMode == 'none' ? tr('Выключены') : tr('Включены'),
            ChatNotificationSettingsScreen(auth: auth),
          ),
          folder(
            Icons.shield_outlined,
            tr('Приватность'),
            tr('{p} · скачивание файлов', {'p': auth.privacyMode == 'friends_only' ? tr('Только по заявке') : tr('Все могут написать')}),
            ChatPrivacyScreen(auth: auth, repo: widget.repo, sync: widget.sync, prefs: prefs, onChanged: widget.onChanged),
          ),
          folder(
            Icons.manage_accounts_outlined,
            tr('Аккаунт'),
            tr('Выход, удаление аккаунта'),
            ChatAccountSettingsScreen(auth: auth, onChanged: widget.onChanged),
          ),
        ],
      ),
    );
  }
}

/// Название языка перевода; пусто — язык системы.
String chatLanguageLabel(String code) {
  final effective = code.isEmpty ? ChatTranslationService.systemLanguageCode() : code;
  for (final l in chatLanguages) {
    if (l.code == effective) return l.label;
  }
  return effective;
}

/// Язык перевода и автоперевод по умолчанию. В конкретном чате
/// автоперевод включается/выключается в меню ⋮.
class ChatTranslationSettingsScreen extends StatelessWidget {
  final ChatPreferences prefs;
  const ChatTranslationSettingsScreen({super.key, required this.prefs});

  /// Язык системы — первым (решение пользователя), остальные следом.
  List<ChatLanguage> get _languages {
    final systemCode = ChatTranslationService.systemLanguageCode();
    final list = [...chatLanguages];
    final i = list.indexWhere((l) => l.code == systemCode);
    if (i > 0) list.insert(0, list.removeAt(i));
    return list;
  }

  Future<void> _pickLanguage(BuildContext context) async {
    final languages = _languages;
    final current = prefs.translationLanguage.isEmpty ? languages.first.code : prefs.translationLanguage;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: ListView(
            children: [
              for (final lang in languages)
                ListTile(
                  title: Text(lang.label),
                  subtitle: lang.code == ChatTranslationService.systemLanguageCode() ? Text(tr('Язык системы')) : null,
                  trailing: lang.code == current ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(ctx).pop(lang.code),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    prefs.translationLanguage = picked == languages.first.code ? '' : picked;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('Язык и перевод'))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(tr('Переводить на'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: Text(chatLanguageLabel(prefs.translationLanguage)),
                subtitle: prefs.translationLanguage.isEmpty ? Text(tr('Язык системы')) : null,
                trailing: const Icon(Icons.expand_more),
                onTap: () => _pickLanguage(context),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Автоперевод во всех чатах')),
              subtitle: Text(tr('Входящие переводятся сразу. В отдельном чате можно включить или выключить в меню ⋮')),
              value: prefs.autoTranslate,
              onChanged: (v) => prefs.autoTranslate = v,
            ),
            const SizedBox(height: 8),
            Text(
              tr('Переводятся последние 15 сообщений; листаете выше — ещё 20, дальше по 30. Одно сообщение можно перевести вручную: долгое нажатие → «Перевести».'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Уведомления о сообщениях.
class ChatNotificationSettingsScreen extends StatefulWidget {
  final ChatAuthService auth;
  const ChatNotificationSettingsScreen({super.key, required this.auth});

  @override
  State<ChatNotificationSettingsScreen> createState() => _ChatNotificationSettingsScreenState();
}

class _ChatNotificationSettingsScreenState extends State<ChatNotificationSettingsScreen> {
  /// `update...` пишут локальный кэш сразу, до сети — переключатель не
  /// ждёт сервер; при ошибке кэш откатывается и видно SnackBar.
  Future<void> _apply(Future<void> Function() update) async {
    final future = update();
    setState(() {});
    try {
      await future;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Уведомления'))),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(tr('Сообщения')),
            subtitle: Text(tr('Личные чаты и группы')),
            value: auth.personalPushMode != 'none',
            onChanged: (v) => _apply(() => auth.updatePersonalPushMode(v ? 'all' : 'none')),
          ),
        ],
      ),
    );
  }
}

/// Аккаунт мессенджера: выход и удаление.
class ChatAccountSettingsScreen extends StatelessWidget {
  final ChatAuthService auth;
  final VoidCallback onChanged;
  const ChatAccountSettingsScreen({super.key, required this.auth, required this.onChanged});

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить аккаунт мессенджера?')),
        content: Text(
          tr('Никнейм, код контакта, друзья, заявки и членство в группах будут удалены безвозвратно. Переписка, уже сохранённая на этом устройстве, останется. Отменить нельзя.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Отмена'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await auth.deleteAccount();
      onChanged();
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Аккаунт'))),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(auth.nickname),
            subtitle: Text(tr('Код контакта: {chatCode}', {'chatCode': auth.chatCode})),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(tr('Выйти из мессенджера')),
            subtitle: Text(tr('Переписка на устройстве сохранится')),
            onTap: () {
              auth.signOutLocally();
              onChanged();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: error),
            title: Text(tr('Удалить аккаунт'), style: TextStyle(color: error)),
            subtitle: Text(tr('Профиль, друзья, группы на сервере — необратимо')),
            onTap: () => _delete(context),
          ),
        ],
      ),
    );
  }
}
