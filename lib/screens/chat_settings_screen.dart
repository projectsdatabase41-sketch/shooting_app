import 'package:flutter/material.dart';

import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/local_db_service.dart';
import 'chat_appearance_screen.dart';
import 'chat_privacy_screen.dart';

/// Единая точка входа во все настройки чата (решение пользователя,
/// вместо трёх разных пунктов в панели) — оформление и приватность
/// открываются отдельными страницами (они сами по себе большие),
/// уведомления — прямо здесь, это всего один переключатель и список.
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
  bool get _pushEnabled => widget.auth.personalPushMode != 'none';

  Future<void> _setPushEnabled(bool enabled) => _updatePush(enabled ? 'all' : 'none');

  /// Обе `update...` пишут свой локальный кэш СИНХРОННО в самом начале
  /// (до первого await внутри) — вызов ниже уже обновил то, что читает
  /// `_pushEnabled`/`_pushMode`, поэтому `setState` сразу после вызова
  /// показывает новый выбор без задержки на сеть; сеть просто донастраивает
  /// сервер в фоне и откатывает кэш назад, если не получилось (тогда
  /// заметно по SnackBar и второму `setState`).
  Future<void> _setCallAlertsEnabled(bool enabled) async {
    setState(() {});
    try {
      await widget.auth.updateCallAlertsEnabled(enabled);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _updatePush(String personal) async {
    final future = widget.auth.updatePersonalPushMode(personal);
    setState(() {});
    widget.onChanged();
    try {
      await future;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Оформление чата'),
            subtitle: const Text('Перевод, цвета и тени сообщений'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChatAppearanceScreen(prefs: widget.prefs, db: widget.db),
            )),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.download_outlined),
            title: const Text('Разрешить скачивание моих фото и файлов'),
            subtitle: const Text('Кнопка "Сохранить" у ОТПРАВЛЕННЫХ мной вложений'),
            value: widget.prefs.photoDownloadMode != 'off',
            onChanged: (v) => setState(() => widget.prefs.photoDownloadMode = v ? 'all' : 'off'),
          ),
          if (widget.prefs.photoDownloadMode != 'off')
            for (final (value, label) in const [('all', 'Во всех чатах'), ('personal', 'Только в личных')])
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 16),
                dense: true,
                title: Text(label),
                trailing: widget.prefs.photoDownloadMode == value ? const Icon(Icons.check) : null,
                onTap: () => setState(() => widget.prefs.photoDownloadMode = value),
              ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Уведомления приложения'),
            value: _pushEnabled,
            onChanged: _setPushEnabled,
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.campaign_outlined),
            title: const Text('Громкий сигнал "Позвать"'),
            subtitle: const Text('Рингтон устройства и усиленная вибрация вместо обычного уведомления'),
            value: widget.auth.callAlertsEnabled,
            onChanged: _setCallAlertsEnabled,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Приватность'),
            subtitle: Text(widget.auth.privacyMode == 'friends_only' ? 'Только по заявке' : 'Все могут написать'),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatPrivacyScreen(
                  auth: widget.auth,
                  repo: widget.repo,
                  sync: widget.sync,
                  onChanged: widget.onChanged,
                ),
              ));
              widget.onChanged();
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
            title: Text('Удалить аккаунт', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('Профиль, друзья, переписка на сервере — необратимо'),
            onTap: _deleteAccount,
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить аккаунт чата?'),
        content: const Text(
          'Никнейм, код контакта, список друзей и заявки будут удалены безвозвратно. '
          'Переписка, уже сохранённая на этом устройстве, останется в контактах локально. '
          'Отменить это действие нельзя.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.auth.deleteAccount();
      widget.onChanged();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
