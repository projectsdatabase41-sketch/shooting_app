import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../logic/avatar_utils.dart';
import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_settings.dart';
import '../services/chat_sync_service.dart';
import '../services/supabase_auth_service.dart' show AuthException;
import '../state/app_data_store.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';
import 'chat_thread_screen.dart';

/// Публичный чат между пользователями приложения — отдельная учётная
/// запись от личной базы тренировок (см. `ChatAuthService`). Список
/// контактов + переход в переписку; опрос новых сообщений — редкий
/// таймер, пока экран открыт (пункт из обсуждения: без push в MVP).
class ChatHomeScreen extends StatefulWidget {
  const ChatHomeScreen({super.key});

  @override
  State<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  late final ChatAuthService _auth;
  late final ChatMessagesRepository _repo;
  late final ChatSyncService _sync;
  Timer? _pollTimer;
  List<ChatContact> _contacts = [];

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    _auth = ChatAuthService(db);
    _repo = ChatMessagesRepository(db);
    _sync = ChatSyncService(_auth, _repo);
    _reload();
    if (_auth.isSignedIn) _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _contacts = _repo.listContacts());

  void _startPolling() {
    _pollTimer?.cancel();
    // Раз в 20 секунд, пока экран открыт — редкий опрос вместо push
    // (решение пользователя: сначала MVP без push).
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final added = await _sync.pollIncoming();
      if (added > 0 && mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ChatSettings.isConfigured) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.forum_outlined,
          text: 'Публичный чат скоро появится — сервер для него ещё не подключён',
        ),
      );
    }
    if (!_auth.isSignedIn) {
      return _ChatAuthScreen(auth: _auth, onSignedIn: () {
        _reload();
        _startPolling();
        setState(() {});
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чат'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Мой профиль',
            onPressed: () => _openProfile(context),
          ),
          IconButton(
            icon: const Icon(Icons.person_add_alt_outlined),
            tooltip: 'Добавить контакт',
            onPressed: () => _openAddContact(context),
          ),
        ],
      ),
      body: _contacts.isEmpty
          ? const EmptyState(
              icon: Icons.forum_outlined,
              text: 'Пока нет контактов — добавьте по коду через значок вверху',
            )
          : ListView.builder(
              itemCount: _contacts.length,
              itemBuilder: (context, i) {
                final c = _contacts[i];
                final last = _repo.lastForContact(c.id);
                final unread = _repo.unreadCount(c.id);
                return ListTile(
                  leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                  title: Text(c.nickname),
                  subtitle: last == null
                      ? const Text('Сообщений пока нет')
                      : Text(last.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: unread > 0
                      ? CircleAvatar(radius: 11, child: Text('$unread', style: const TextStyle(fontSize: 11)))
                      : null,
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ChatThreadScreen(contact: c, auth: _auth, repo: _repo, sync: _sync),
                    ));
                    _reload();
                  },
                );
              },
            ),
    );
  }

  Future<void> _openProfile(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProfileSheet(auth: _auth),
    );
    setState(() {});
  }

  Future<void> _openAddContact(BuildContext context) async {
    final codeCtrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить контакт'),
        content: TextField(
          controller: codeCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Код контакта', hintText: 'XXXX-XXXX'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(codeCtrl.text.trim()),
            child: const Text('Найти'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;
    try {
      final found = await _auth.resolveChatCode(code);
      if (found == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Контакт с таким кодом не найден')));
        return;
      }
      _repo.addContact(ChatContact(
        id: found.userId,
        nickname: found.nickname,
        chatCode: code,
        avatarBase64: found.avatarBase64,
        addedAt: DateTime.now(),
      ));
      _reload();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Вход/регистрация в чате — отдельная учётная запись от личной базы.
class _ChatAuthScreen extends StatefulWidget {
  final ChatAuthService auth;
  final VoidCallback onSignedIn;
  const _ChatAuthScreen({required this.auth, required this.onSignedIn});

  @override
  State<_ChatAuthScreen> createState() => _ChatAuthScreenState();
}

class _ChatAuthScreenState extends State<_ChatAuthScreen> {
  bool _register = true;
  bool _busy = false;
  String? _error;
  final _nickname = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _avatarBase64;

  @override
  void dispose() {
    _nickname.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.first.bytes;
    if (bytes == null) return;
    final b64 = AvatarUtils.processToBase64(bytes);
    if (b64 == null) return;
    setState(() => _avatarBase64 = b64);
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        final ok = await widget.auth.signUp(
          nickname: _nickname.text,
          email: _email.text,
          password: _password.text,
          avatarBase64: _avatarBase64,
        );
        if (!ok) {
          setState(() => _error = 'Аккаунт создан. Подтвердите почту письмом (если это включено) и войдите.');
          return;
        }
      } else {
        await widget.auth.signIn(email: _email.text, password: _password.text);
      }
      widget.onSignedIn();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Чат')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Регистрация')),
              ButtonSegment(value: false, label: Text('Вход')),
            ],
            selected: {_register},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _register = v.first),
          ),
          const SizedBox(height: 16),
          if (_register) ...[
            Center(
              child: GestureDetector(
                onTap: _pickAvatar,
                child: Stack(
                  children: [
                    ChatAvatar(base64: _avatarBase64, nickname: _nickname.text, radius: 40),
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(radius: 12, child: Icon(Icons.edit, size: 14)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: _nickname, decoration: const InputDecoration(labelText: 'Никнейм')),
            const SizedBox(height: 10),
          ],
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
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_register ? 'Зарегистрироваться' : 'Войти'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _ProfileSheet extends StatefulWidget {
  final ChatAuthService auth;
  const _ProfileSheet({required this.auth});

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  bool _busy = false;

  Future<void> _changeAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.first.bytes;
    if (bytes == null) return;
    final b64 = AvatarUtils.processToBase64(bytes);
    if (b64 == null) return;
    setState(() => _busy = true);
    try {
      await widget.auth.updateAvatar(b64);
    } catch (_) {
      // молча — профиль всё равно перечитается при следующем входе
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _busy ? null : _changeAvatar,
              child: ChatAvatar(base64: auth.avatarBase64, nickname: auth.nickname, radius: 40),
            ),
            const SizedBox(height: 12),
            Text(auth.nickname, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            const Text('Ваш код контакта — дайте его собеседнику, чтобы он вас добавил'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: auth.chatCode));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован')));
              },
              icon: const Icon(Icons.copy),
              label: Text(auth.chatCode),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                widget.auth.signOutLocally();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.logout),
              label: const Text('Выйти из чата'),
            ),
          ],
        ),
      ),
    );
  }
}
