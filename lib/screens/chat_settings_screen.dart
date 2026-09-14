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
  /// Под капотом по-прежнему два разных поля на сервере
  /// (`personal_push_mode`, `global_push_mode`, см. `ChatAuthService`/
  /// send-chat-push) — экран просто комбинирует их в один понятный выбор.
  static const List<(String, String)> _pushModes = [
    ('personal_only', 'Только личный чат'),
    ('personal_and_replies', 'Личный чат и ответы на мои сообщения в общем чате'),
    ('personal_and_all', 'Личный и общий чат'),
  ];

  bool get _pushEnabled => widget.auth.personalPushMode != 'none' || widget.auth.globalPushMode != 'none';

  String get _pushMode {
    if (widget.auth.globalPushMode == 'all') return 'personal_and_all';
    if (widget.auth.globalPushMode == 'replies') return 'personal_and_replies';
    return 'personal_only';
  }

  Future<void> _setPushEnabled(bool enabled) => _updatePush(
        personal: enabled ? 'all' : 'none',
        // Выключали и раньше был выбран какой-то режим общего чата —
        // включили обратно тем же режимом, а не молча только личным.
        global: enabled ? (widget.auth.globalPushMode == 'none' ? 'all' : widget.auth.globalPushMode) : 'none',
      );

  Future<void> _setPushMode(String mode) => _updatePush(
        personal: 'all',
        global: switch (mode) {
          'personal_and_all' => 'all',
          'personal_and_replies' => 'replies',
          _ => 'none',
        },
      );

  Future<void> _updatePush({required String personal, required String global}) async {
    try {
      await Future.wait([widget.auth.updatePersonalPushMode(personal), widget.auth.updateGlobalPushMode(global)]);
      widget.onChanged();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Уведомления приложения'),
            value: _pushEnabled,
            onChanged: _setPushEnabled,
          ),
          if (_pushEnabled)
            for (final (value, label) in _pushModes)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 16),
                dense: true,
                title: Text(label),
                trailing: _pushMode == value ? const Icon(Icons.check) : null,
                onTap: () => _setPushMode(value),
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
        ],
      ),
    );
  }
}
