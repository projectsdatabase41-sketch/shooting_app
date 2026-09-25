import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../logic/avatar_utils.dart';
import '../logic/adaptive_poller.dart';
import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_settings.dart';
import '../services/chat_sync_service.dart';
import '../services/local_db_service.dart';
import '../services/push_service.dart';
import '../services/remote_config.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';
import 'chat_settings_screen.dart';
import 'chat_thread_screen.dart';

/// Мессенджер — отдельная учётная запись от личной базы тренировок (см.
/// `ChatAuthService`). Главный экран — список собеседников; переписка с
/// одним контактом открывается отдельным экраном (`ChatThreadScreen`).
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
  late final ChatPreferences _prefs;
  PollLoop? _pollLoop;
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
    _prefs = ChatPreferences(_db);
    _reload();
    if (_auth.isSignedIn) {
      _startPolling();
      PushService(_auth).init();
      _syncFriends();
    } else if (_mainAuth.isSignedIn) {
      _autoProvisioning = true;
      _ensureChatSession();
    }
  }

  @override
  void dispose() {
    _pollLoop?.stop();
    super.dispose();
  }

  void _reload() => setState(() => _contacts = _repo.listContacts());

  /// Заявки/друзья живут на сервере (см. `ChatAuthService.listFriends`) —
  /// после переустановки или на новом телефоне их ещё нет только в
  /// локальном `chat_contacts`, здесь пробел восполняется при входе.
  Future<void> _syncFriends() async {
    final friends = await _auth.listFriends();
    if (friends.isEmpty) return;
    for (final f in friends) {
      _repo.addContact(ChatContact(
        id: f.userId,
        nickname: f.nickname,
        chatCode: '',
        avatarBase64: f.avatarBase64,
        about: f.about,
        addedAt: DateTime.now(),
      ));
    }
    if (mounted) _reload();
  }

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
          _syncFriends();
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
    _pollLoop?.stop();
    // Адаптивный опрос вместо фиксированных 20 секунд (решение
    // пользователя, подготовка к 1000+ пользователей): часто, пока идёт
    // переписка, редко в покое, ещё реже — если сервер отвечает тяжело.
    // Личный опрос и так дешёвый (в транзитной таблице только МОИ строки).
    _pollLoop = PollLoop(
      poller: AdaptivePoller(
          min: const Duration(seconds: 10), max: const Duration(seconds: 60), scale: () => RemoteConfig.pollScale),
      tick: () async {
        final added = await _sync.pollIncoming();
        // _reload(), а не голый setState — новое входящее от ещё не
        // добавленного отправителя заводит контакт автоматически (см.
        // ChatSyncService.pollIncoming), и он должен сразу появиться в
        // списке слева, а не только после ручного обновления экрана.
        if (added > 0 && mounted) _reload();
        return added > 0;
      },
    )..start();
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
          _syncFriends();
          setState(() {});
        },
      );
    }

    return _ChatContactsView(
      auth: _auth,
      repo: _repo,
      sync: _sync,
      prefs: _prefs,
      db: _db,
      contacts: _contacts,
      onContactsChanged: _reload,
      onOpenThread: (contact) async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatThreadScreen(contact: contact, auth: _auth, repo: _repo, sync: _sync, prefs: _prefs),
        ));
        _reload();
      },
    );
  }
}

/// Главный экран мессенджера — список тех, с кем переписываешься (как в
/// обычных мессенджерах): аватар, ник, строка «о себе», последнее сообщение
/// и время, счётчик непрочитанных. Общий чат убран (решение пользователя,
/// позже — сообщества).
class _ChatContactsView extends StatelessWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;
  final LocalDbService db;
  final List<ChatContact> contacts;
  final VoidCallback onContactsChanged;
  final void Function(ChatContact) onOpenThread;

  const _ChatContactsView({
    required this.auth,
    required this.repo,
    required this.sync,
    required this.prefs,
    required this.db,
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
      final contact = ChatContact(
        id: found.userId,
        nickname: found.nickname,
        chatCode: code,
        avatarBase64: found.avatarBase64,
        about: found.about,
        addedAt: DateTime.now(),
      );
      repo.addContact(contact);
      onContactsChanged();
      onOpenThread(contact);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Все контакты по алфавиту (и те, с кем ещё не переписывались).
  void _openContacts(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: contacts.isEmpty
              ? const EmptyState(icon: Icons.people_outline, text: 'Контактов пока нет — добавьте по коду')
              : ListView(
                  children: [
                    for (final c in contacts)
                      ListTile(
                        leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                        title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                        subtitle: c.about.isEmpty ? null : Text(c.about, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          onOpenThread(c);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  static String _time(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) return DateFormat.Hm().format(t);
    if (t.year == now.year) return DateFormat('dd.MM').format(t);
    return DateFormat('dd.MM.yy').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Диалоги с историей — по времени последнего сообщения, без истории —
    // в конце по алфавиту (порядок из repo.listContacts).
    final last = {for (final c in contacts) c.id: repo.lastForContact(c.id)};
    final sorted = [...contacts]..sort((a, b) {
        final ta = last[a.id]?.createdAt, tb = last[b.id]?.createdAt;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      });
    void openSettings() => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatSettingsScreen(
            auth: auth,
            repo: repo,
            sync: sync,
            prefs: prefs,
            db: db,
            onChanged: onContactsChanged,
          ),
        ));
    return Scaffold(
      appBar: AppBar(title: const Text('Мессенджер')),
      // Шторка слева, как в Telegram: профиль, контакты, настройки.
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  _editProfile(context);
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ChatAvatar(base64: auth.avatarBase64, nickname: auth.nickname, radius: 32),
                      const SizedBox(height: 12),
                      Text(auth.nickname, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                      if (auth.about.isNotEmpty)
                        Text(auth.about, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                      Text('Код: ${auth.chatCode}', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: const Text('Контакты'),
                trailing: Text('${contacts.length}'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openContacts(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_add_alt_outlined),
                title: const Text('Добавить по коду'),
                onTap: () {
                  Navigator.of(context).pop();
                  _addContact(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Настройки'),
                onTap: () {
                  Navigator.of(context).pop();
                  openSettings();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Выйти из чата'),
                onTap: () {
                  Navigator.of(context).pop();
                  auth.signOutLocally();
                  onContactsChanged();
                },
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Добавить по коду',
        onPressed: () => _addContact(context),
        child: const Icon(Icons.edit_outlined),
      ),
      body: Column(
        children: [
          Expanded(
            child: sorted.isEmpty
                ? const EmptyState(
                    icon: Icons.forum_outlined,
                    text: 'Пока нет собеседников — нажмите кнопку и введите код контакта',
                  )
                : ListView.builder(
                    itemCount: sorted.length,
                    itemBuilder: (context, i) {
                      final c = sorted[i];
                      final m = last[c.id];
                      final unread = repo.unreadCount(c.id);
                      final sub = m != null ? ChatSyncService.previewOf(m) : c.about;
                      return ListTile(
                        leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                        title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (m != null && c.about.isNotEmpty)
                              Text(c.about,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                            if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (m != null) Text(_time(m.createdAt), style: theme.textTheme.bodySmall),
                            if (unread > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: CircleAvatar(radius: 11, child: Text('$unread', style: const TextStyle(fontSize: 11))),
                              ),
                          ],
                        ),
                        onTap: () => onOpenThread(c),
                      );
                    },
                  ),
          ),
        ],
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
      appBar: AppBar(title: const Text('Мессенджер')),
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
  late final TextEditingController _about = TextEditingController(text: widget.auth.about);

  @override
  void dispose() {
    _nickname.dispose();
    _about.dispose();
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

  Future<void> _saveAbout() async {
    final value = _about.text.trim();
    if (value == widget.auth.about) return;
    setState(() => _busy = true);
    try {
      await widget.auth.updateAbout(value);
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
            const SizedBox(height: 12),
            TextField(
              controller: _about,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: 'О себе',
                hintText: 'Клуб, город, дисциплина — чтобы вас узнавали',
                suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _busy ? null : _saveAbout),
              ),
              onSubmitted: (_) => _saveAbout(),
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
