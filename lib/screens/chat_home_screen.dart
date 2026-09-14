import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../logic/avatar_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_global_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_global_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_settings.dart';
import '../services/chat_sync_service.dart';
import '../services/local_db_service.dart';
import '../services/push_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';
import 'chat_thread_screen.dart';

/// Публичный чат — отдельная учётная запись от личной базы тренировок
/// (см. `ChatAuthService`). Устройство как в Telegram (решение
/// пользователя): слева выезжающая панель с контактами и настройками
/// профиля, основной экран — общая (всемирная) лента на всех
/// пользователей платформы; личная переписка с одним контактом
/// открывается отдельным экраном (`ChatThreadScreen`) поверх этого.
class ChatHomeScreen extends StatefulWidget {
  const ChatHomeScreen({super.key});

  @override
  State<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  late final LocalDbService _db;
  late final ChatAuthService _auth;
  late final SupabaseAuthService _mainAuth;
  late final ChatMessagesRepository _repo;
  late final ChatSyncService _sync;
  late final ChatGlobalService _global;
  Timer? _pollTimer;
  List<ChatContact> _contacts = [];

  /// Идёт попытка тихого входа в чат тем же email, что и основной вход
  /// (см. `_ensureChatSession`) — пока она не завершилась, форму
  /// регистрации/входа не показываем, чтобы не мигать ей на долю
  /// секунды перед автоматическим входом.
  bool _autoProvisioning = false;

  @override
  void initState() {
    super.initState();
    _db = context.read<AppDataStore>().db;
    _auth = ChatAuthService(_db);
    _mainAuth = SupabaseAuthService(_db);
    _repo = ChatMessagesRepository(_db);
    _sync = ChatSyncService(_auth, _repo);
    _global = ChatGlobalService(_auth);
    _reload();
    if (_auth.isSignedIn) {
      _startPolling();
      PushService(_auth).init();
    } else if (_mainAuth.isSignedIn) {
      _autoProvisioning = true;
      _ensureChatSession();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _contacts = _repo.listContacts());

  /// Заводит/открывает чат-аккаунт тем же email, что и основной вход —
  /// без видимой формы регистрации (решение пользователя: трение
  /// отдельной регистрации — главная причина малого числа пользователей
  /// чата). Настоящий пароль основного входа приложению недоступен и
  /// никогда не сохраняется (см. `SupabaseAuthService`) — для чата
  /// генерируется отдельный секрет, который хранится не локально, а в
  /// облаке САМОГО пользователя (`project_settings.chat_password` его
  /// личного проекта), чтобы это работало на любом его устройстве, а не
  /// только на первом.
  Future<void> _ensureChatSession() async {
    final email = _mainAuth.email;
    if (email.isEmpty) {
      setState(() => _autoProvisioning = false);
      return;
    }
    try {
      final stored = await _mainAuth.fetchChatPassword();
      if (stored != null) {
        try {
          await _auth.signIn(email: email, password: stored);
        } on AuthException {
          // Сохранённый пароль больше не подходит (аккаунт пересоздан
          // вручную и т.п.) — падаем в обычную форму, чем гадать дальше.
        }
      } else {
        final generated = _generatePassword();
        try {
          final ok = await _auth.signUp(nickname: email.split('@').first, email: email, password: generated);
          if (ok) await _mainAuth.saveChatPassword(generated);
        } on AuthException {
          // Скорее всего "уже зарегистрирован" — чат-аккаунт с этой
          // почтой уже существует с другим, неизвестным нам паролем
          // (заведён вручную ещё до этой возможности). Остаётся только
          // попросить войти самостоятельно один последний раз — успешный
          // ручной вход сам сохранит пароль на будущее, см.
          // _ChatAuthScreenState._maybeSaveChatPasswordForMainAccount.
        }
      }
    } finally {
      if (mounted) {
        setState(() => _autoProvisioning = false);
        if (_auth.isSignedIn) {
          _startPolling();
          PushService(_auth).init();
        }
      }
    }
  }

  static String _generatePassword() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    // Раз в 20 секунд, пока экран открыт — редкий опрос вместо push
    // (решение пользователя: сначала MVP без push).
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final added = await _sync.pollIncoming();
      // _reload(), а не голый setState — новое входящее от ещё не
      // добавленного отправителя заводит контакт автоматически (см.
      // ChatSyncService.pollIncoming), и он должен сразу появиться в
      // списке слева, а не только после ручного обновления экрана.
      if (added > 0 && mounted) _reload();
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
      if (_autoProvisioning) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return _ChatAuthScreen(
        auth: _auth,
        db: _db,
        onSignedIn: () {
          _reload();
          _startPolling();
          PushService(_auth).init();
          setState(() {});
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Общий чат')),
      drawer: _ChatDrawer(
        auth: _auth,
        repo: _repo,
        contacts: _contacts,
        onContactsChanged: _reload,
        onOpenThread: (contact) async {
          Navigator.of(context).pop(); // закрыть панель
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatThreadScreen(contact: contact, auth: _auth, repo: _repo, sync: _sync),
          ));
          _reload();
        },
      ),
      body: _GlobalChatBody(auth: _auth, global: _global, repo: _repo, onContactAdded: _reload),
    );
  }
}

/// Левая панель (решение пользователя, "как в телеграме") — профиль
/// (аватар, никнейм, код контакта) и список личных контактов.
class _ChatDrawer extends StatelessWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final List<ChatContact> contacts;
  final VoidCallback onContactsChanged;
  final void Function(ChatContact) onOpenThread;

  const _ChatDrawer({
    required this.auth,
    required this.repo,
    required this.contacts,
    required this.onContactsChanged,
    required this.onOpenThread,
  });

  Future<void> _editProfile(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProfileSheet(auth: auth),
    );
    onContactsChanged();
  }

  Future<void> _addContact(BuildContext context) async {
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
          FilledButton(onPressed: () => Navigator.of(ctx).pop(codeCtrl.text.trim()), child: const Text('Найти')),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;
    try {
      final found = await auth.resolveChatCode(code);
      if (found == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Контакт с таким кодом не найден')));
        return;
      }
      repo.addContact(ChatContact(
        id: found.userId,
        nickname: found.nickname,
        chatCode: code,
        avatarBase64: found.avatarBase64,
        addedAt: DateTime.now(),
      ));
      onContactsChanged();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => _editProfile(context),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ChatAvatar(base64: auth.avatarBase64, nickname: auth.nickname, radius: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(auth.nickname, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                          Text('Код: ${auth.chatCode}',
                              style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const Icon(Icons.edit_outlined, size: 18),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(child: Text('Контакты', style: theme.textTheme.titleSmall)),
                  IconButton(
                    icon: const Icon(Icons.person_add_alt_outlined),
                    tooltip: 'Добавить по коду',
                    onPressed: () => _addContact(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: contacts.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Пока нет контактов — добавьте по коду или из общего чата'),
                    )
                  : ListView.builder(
                      itemCount: contacts.length,
                      itemBuilder: (context, i) {
                        final c = contacts[i];
                        final unread = repo.unreadCount(c.id);
                        return ListTile(
                          leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                          title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                          trailing: unread > 0
                              ? CircleAvatar(radius: 11, child: Text('$unread', style: const TextStyle(fontSize: 11)))
                              : null,
                          onTap: () => onOpenThread(c),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Выйти из чата'),
              onTap: () {
                auth.signOutLocally();
                Navigator.of(context).pop();
                onContactsChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Общая (всемирная) лента — главный экран чата.
class _GlobalChatBody extends StatefulWidget {
  final ChatAuthService auth;
  final ChatGlobalService global;
  final ChatMessagesRepository repo;
  final VoidCallback onContactAdded;

  const _GlobalChatBody({required this.auth, required this.global, required this.repo, required this.onContactAdded});

  @override
  State<_GlobalChatBody> createState() => _GlobalChatBodyState();
}

class _GlobalChatBodyState extends State<_GlobalChatBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _pollTimer;
  List<ChatGlobalMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final messages = await widget.global.fetchRecent();
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _loading = false;
    });
    if (silent) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() => _sending = true);
    try {
      await widget.global.send(text);
      await _load();
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Пункт списка правок: "общедоступный чат со списком пользователей" —
  /// список тех, кто уже писал в ленту (по загруженным сообщениям), с
  /// возможностью сразу добавить в контакты для личной переписки. Код
  /// контакта тут не нужен — id/никнейм/аватар уже известны из
  /// собственных публичных сообщений человека.
  void _openParticipants(BuildContext context) {
    final seen = <String, ChatGlobalMessage>{};
    for (final m in _messages) {
      seen[m.senderId] = m;
    }
    final participants = seen.values.where((m) => m.senderId != widget.auth.userId).toList()
      ..sort((a, b) => (a.senderNickname ?? '').compareTo(b.senderNickname ?? ''));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: participants.isEmpty
              ? const EmptyState(icon: Icons.groups_outlined, text: 'Пока никто, кроме вас, не писал')
              : ListView.builder(
                  itemCount: participants.length,
                  itemBuilder: (context, i) {
                    final p = participants[i];
                    return ListTile(
                      leading: ChatAvatar(base64: p.senderAvatarBase64, nickname: p.senderNickname ?? '?'),
                      title: Text(p.senderNickname ?? '—'),
                      trailing: OutlinedButton(
                        onPressed: () {
                          widget.repo.addContact(ChatContact(
                            id: p.senderId,
                            nickname: p.senderNickname ?? '—',
                            chatCode: '',
                            avatarBase64: p.senderAvatarBase64,
                            addedAt: DateTime.now(),
                          ));
                          widget.onContactAdded();
                          Navigator.of(ctx).pop();
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('Добавлено в контакты')));
                        },
                        child: const Text('В контакты'),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              const Expanded(child: SizedBox()),
              TextButton.icon(
                onPressed: () => _openParticipants(context),
                icon: const Icon(Icons.groups_outlined, size: 18),
                label: const Text('Участники'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _messages.isEmpty
                  ? const EmptyState(icon: Icons.public_outlined, text: 'В общем чате пока тихо — напишите первым')
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) =>
                          _GlobalBubble(message: _messages[i], mine: _messages[i].senderId == widget.auth.userId),
                    ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(hintText: 'Сообщение всем'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlobalBubble extends StatelessWidget {
  final ChatGlobalMessage message;
  final bool mine;
  const _GlobalBubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bg = mine ? cs.primaryContainer : cs.surfaceContainerHigh;
    final fg = mine ? cs.onPrimaryContainer : cs.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.senderNickname ?? '—',
                  style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
              ),
            SelectableText(message.text, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
            const SizedBox(height: 4),
            Text(
              DateFormat('HH:mm').format(message.createdAt.toLocal()),
              style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.65)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Вход/регистрация в чате — отдельная учётная запись от личной базы.
class _ChatAuthScreen extends StatefulWidget {
  final ChatAuthService auth;
  final LocalDbService db;
  final VoidCallback onSignedIn;
  const _ChatAuthScreen({required this.auth, required this.db, required this.onSignedIn});

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
    final b64 = await AvatarUtils.pickAndProcess();
    if (b64 == null) return;
    setState(() => _avatarBase64 = b64);
  }

  Future<void> _forgotPassword() async {
    final emailCtrl = TextEditingController(text: _email.text);
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Восстановление пароля'),
        content: TextField(
          controller: emailCtrl,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Почта'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(emailCtrl.text.trim()), child: const Text('Отправить')),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await widget.auth.requestPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Если такая почта зарегистрирована — письмо со ссылкой уже отправлено')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// После успешного ручного входа/регистрации — если почта совпадает
  /// с основным входом и там ещё не сохранён пароль чата, сохраняет
  /// его сейчас. "Догоняет" тихий вход (`ChatHomeScreen.
  /// _ensureChatSession`) для аккаунтов, заведённых вручную ещё до
  /// этой возможности или после её сбоя (например, "уже
  /// зарегистрирован" при первой попытке) — следующий раз войдёт уже
  /// без формы.
  Future<void> _maybeSaveChatPasswordForMainAccount(String password) async {
    final mainAuth = SupabaseAuthService(widget.db);
    if (!mainAuth.isSignedIn) return;
    if (mainAuth.email.trim().toLowerCase() != _email.text.trim().toLowerCase()) return;
    final existing = await mainAuth.fetchChatPassword();
    if (existing != null) return;
    await mainAuth.saveChatPassword(password);
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
          setState(() => _error =
              'Аккаунт создан. Если почта требует подтверждения — перейдите по ссылке из письма, затем войдите через "Вход" (код контакта появится автоматически).');
          return;
        }
      } else {
        await widget.auth.signIn(email: _email.text, password: _password.text);
      }
      await _maybeSaveChatPasswordForMainAccount(_password.text);
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
          if (!_register) ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _forgotPassword, child: const Text('Забыли пароль?')),
            ),
          ],
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

/// Настройки профиля — открывается из левой панели (решение
/// пользователя, "настройки профиля" в том же месте, что контакты).
class _ProfileSheet extends StatefulWidget {
  final ChatAuthService auth;
  const _ProfileSheet({required this.auth});

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  bool _busy = false;
  late final TextEditingController _nickname = TextEditingController(text: widget.auth.nickname);

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    final b64 = await AvatarUtils.pickAndProcess();
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

  Future<void> _saveNickname() async {
    final value = _nickname.text.trim();
    if (value.isEmpty || value == widget.auth.nickname) return;
    setState(() => _busy = true);
    try {
      await widget.auth.updateNickname(value);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
            const SizedBox(height: 16),
            TextField(
              controller: _nickname,
              decoration: InputDecoration(
                labelText: 'Никнейм',
                suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _busy ? null : _saveNickname),
              ),
              onSubmitted: (_) => _saveNickname(),
            ),
            const SizedBox(height: 16),
            const Text('Ваш код контакта — дайте его собеседнику, чтобы он вас добавил'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: auth.chatCode));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован')));
              },
              icon: const Icon(Icons.copy),
              label: Text(auth.chatCode.isEmpty ? '—' : auth.chatCode),
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
