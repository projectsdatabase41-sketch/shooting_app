import 'package:flutter/material.dart';

import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';

/// "Приватность" — режим "все могут написать" (как раньше) или "только
/// по заявке" (первое сообщение от незнакомца видно только после
/// принятия, см. `ChatSyncService.pollIncoming`), плюс список заявок и
/// друзей. Заявки/друзья хранятся на сервере (`chat_friends`), а не
/// только на устройстве — переживают переустановку и смену телефона,
/// в отличие от `chat_contacts` (см. `ChatAuthService.listFriends`).
class ChatPrivacyScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences? prefs;
  final VoidCallback onChanged;

  const ChatPrivacyScreen({
    super.key,
    required this.auth,
    required this.repo,
    required this.sync,
    this.prefs,
    required this.onChanged,
  });

  @override
  State<ChatPrivacyScreen> createState() => _ChatPrivacyScreenState();
}

typedef _Person = ({String userId, String nickname, String? avatarBase64, String about});

class _ChatPrivacyScreenState extends State<ChatPrivacyScreen> {
  bool _loading = true;
  List<({String userId, String nickname, String? avatarBase64, DateTime createdAt})> _requests = [];
  List<_Person> _friends = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final requests = await widget.auth.fetchFriendRequests();
    final friends = await widget.auth.listFriends();
    if (!mounted) return;
    setState(() {
      _requests = requests;
      _friends = friends;
      _loading = false;
    });
  }

  /// updatePrivacyMode пишет локальный кэш синхронно до сети (см.
  /// ChatAuthService) — setState сразу после вызова уже показывает новый
  /// режим, не дожидаясь ответа сервера; откатывается назад при ошибке.
  Future<void> _setMode(String mode) async {
    if (mode == widget.auth.privacyMode) return;
    final future = widget.auth.updatePrivacyMode(mode);
    setState(() {});
    try {
      await future;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        setState(() {});
      }
    }
  }

  Future<void> _accept(String requesterId, String nickname, String? avatarBase64) async {
    try {
      await widget.auth.acceptFriendRequest(requesterId);
      widget.repo.addContact(ChatContact(
        id: requesterId,
        nickname: nickname,
        chatCode: '',
        avatarBase64: avatarBase64,
        addedAt: DateTime.now(),
      ));
      await widget.sync.pollIncoming(); // сразу подтянуть их сообщения, ждавшие принятия
      widget.onChanged();
      await _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _decline(String requesterId) async {
    try {
      await widget.auth.declineFriendRequest(requesterId);
      await _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = widget.auth.privacyMode;
    return Scaffold(
      appBar: AppBar(title: const Text('Приватность')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Кто может написать', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'everyone', label: Text('Все')),
                      ButtonSegment(value: 'friends_only', label: Text('Только по заявке')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => _setMode(s.first),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mode == 'friends_only'
                        ? 'Сообщение от незнакомого человека станет заявкой ниже — вы увидите переписку, только когда примете её.'
                        : 'Первое сообщение от кого угодно сразу добавляет его в контакты, как обычно.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (widget.prefs case final prefs?) ...[
                    const SizedBox(height: 24),
                    Text('Мои фото и файлы', style: theme.textTheme.titleMedium),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Разрешить собеседникам сохранять'),
                      subtitle: const Text('Кнопка «Сохранить» у отправленных мной вложений'),
                      value: prefs.photoDownloadMode != 'off',
                      onChanged: (v) => setState(() => prefs.photoDownloadMode = v ? 'all' : 'off'),
                    ),
                    if (prefs.photoDownloadMode != 'off')
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'all', label: Text('Везде')),
                          ButtonSegment(value: 'personal', label: Text('Только в личных')),
                        ],
                        selected: {prefs.photoDownloadMode},
                        onSelectionChanged: (v) => setState(() => prefs.photoDownloadMode = v.first),
                      ),
                  ],
                  const SizedBox(height: 24),
                  Text('Заявки в друзья', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_requests.isEmpty)
                    Text('Заявок пока нет', style: theme.textTheme.bodySmall)
                  else
                    for (final r in _requests)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: ChatAvatar(base64: r.avatarBase64, nickname: r.nickname),
                          title: Text(r.nickname),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check_circle_outline),
                                tooltip: 'Принять',
                                onPressed: () => _accept(r.userId, r.nickname, r.avatarBase64),
                              ),
                              IconButton(
                                icon: const Icon(Icons.cancel_outlined),
                                tooltip: 'Отклонить',
                                onPressed: () => _decline(r.userId),
                              ),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 24),
                  Text('Друзья', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Хранится на сервере — не теряется при переустановке или смене телефона.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (_friends.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: EmptyState(icon: Icons.people_outline, text: 'Пока никого'),
                    )
                  else
                    for (final f in _friends)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ChatAvatar(base64: f.avatarBase64, nickname: f.nickname),
                        title: Text(f.nickname),
                      ),
                ],
              ),
            ),
    );
  }
}
