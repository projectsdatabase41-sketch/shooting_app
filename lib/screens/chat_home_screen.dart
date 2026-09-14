import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/avatar_utils.dart';
import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_global_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_global_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_settings.dart';
import '../services/chat_sync_service.dart';
import '../services/chat_translation_service.dart';
import '../services/local_db_service.dart';
import '../services/push_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/chat_quick_menu.dart';
import '../widgets/chat_reply_bar.dart';
import '../widgets/empty_state.dart';
import 'attachment_compose_screen.dart';
import 'chat_settings_screen.dart';
import 'chat_thread_screen.dart';
import 'photo_viewer_screen.dart';

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
  late final ChatPreferences _prefs;
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
    _pollTimer?.cancel();
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
          _syncFriends();
          setState(() {});
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Общий чат')),
      drawer: _ChatDrawer(
        auth: _auth,
        repo: _repo,
        sync: _sync,
        prefs: _prefs,
        db: _db,
        contacts: _contacts,
        onContactsChanged: _reload,
        onOpenThread: (contact) async {
          Navigator.of(context).pop(); // закрыть панель
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatThreadScreen(contact: contact, auth: _auth, repo: _repo, sync: _sync, prefs: _prefs),
          ));
          _reload();
        },
      ),
      // resizeToAvoidBottomInset выключен намеренно — тот же приём, что в
      // ChatThreadScreen (см. комментарий там): Scaffold иногда не
      // схлопывает отступ обратно, когда клавиатуру закрывают системным
      // жестом "назад", а не тапом.
      resizeToAvoidBottomInset: false,
      body: AnimatedPadding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        duration: const Duration(milliseconds: 100),
        child: _GlobalChatBody(auth: _auth, global: _global, repo: _repo, prefs: _prefs, onContactAdded: _reload),
      ),
    );
  }
}

/// Левая панель (решение пользователя, "как в телеграме") — профиль
/// (аватар, никнейм, код контакта) и список личных контактов.
class _ChatDrawer extends StatelessWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;
  final LocalDbService db;
  final List<ChatContact> contacts;
  final VoidCallback onContactsChanged;
  final void Function(ChatContact) onOpenThread;

  const _ChatDrawer({
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
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Настройки'),
              subtitle: const Text('Оформление, уведомления, приватность'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatSettingsScreen(
                    auth: auth,
                    repo: repo,
                    sync: sync,
                    prefs: prefs,
                    db: db,
                    onChanged: onContactsChanged,
                  ),
                ));
              },
            ),
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
  final ChatPreferences prefs;
  final VoidCallback onContactAdded;

  const _GlobalChatBody({
    required this.auth,
    required this.global,
    required this.repo,
    required this.prefs,
    required this.onContactAdded,
  });

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
  ChatGlobalMessage? _replyingTo;

  /// Перевод — та же "маска" и тот же тумблер, что в личном чате (см.
  /// `ChatThreadScreen`), просто своя копия состояния для этой ленты.
  final Map<String, String> _translations = {};
  final Set<String> _translating = {};
  final Map<String, bool> _maskOverride = {};
  final Map<String, String> _translationErrors = {};
  final ChatTranslationService _translator = ChatTranslationService();

  static const int _translateBatch = 10;
  int _translateVisibleCount = _translateBatch;
  String _lastTranslationLanguage = '';

  @override
  void initState() {
    super.initState();
    _lastTranslationLanguage = widget.prefs.translationLanguage;
    widget.prefs.addListener(_onPrefsChanged);
    _loadFromCache();
    _load();
    _scroll.addListener(_onScroll);
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  /// Мгновенный снимок последней загрузки, пока настоящий запрос ещё в
  /// пути — раньше экран показывал крутилку при каждом открытии, даже
  /// для уже виденной ленты (решение пользователя: не должно "постоянно
  /// подгружаться").
  void _loadFromCache() {
    final cached = widget.repo.cachedGlobalMessages();
    if (cached.isEmpty) return;
    final hidden = widget.prefs.hiddenGlobalIds;
    setState(() {
      _messages = hidden.isEmpty ? cached : cached.where((m) => !hidden.contains(m.id)).toList();
      _loading = false;
    });
    _autoTranslateIncoming();
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefsChanged);
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onPrefsChanged() {
    if (!mounted) return;
    if (widget.prefs.translationLanguage != _lastTranslationLanguage) {
      _lastTranslationLanguage = widget.prefs.translationLanguage;
      setState(() {
        _translations.clear();
        _maskOverride.clear();
        _translationErrors.clear();
      });
      _autoTranslateIncoming();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _translateVisibleCount >= _messages.length) return;
    if (_scroll.position.pixels <= _scroll.position.minScrollExtent + 200) {
      _translateVisibleCount += _translateBatch;
      _autoTranslateIncoming();
    }
  }

  bool _isMasked(ChatGlobalMessage m) {
    final override = _maskOverride[m.id];
    if (override != null) return override;
    return widget.prefs.autoTranslate && m.senderId != widget.auth.userId && _translations.containsKey(m.id);
  }

  Future<void> _translate(ChatGlobalMessage m, {bool silent = false}) async {
    if (m.text == null || m.text!.isEmpty) return;
    setState(() {
      _translating.add(m.id);
      _translationErrors.remove(m.id);
    });
    try {
      final translated =
          await _translator.translateIfNeeded(m.text!, targetLanguage: widget.prefs.translationLanguage);
      if (!mounted) return;
      setState(() {
        if (translated != null) _translations[m.id] = translated;
        _translating.remove(m.id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating.remove(m.id);
        _translationErrors[m.id] = '$e';
      });
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось перевести: $e')));
      }
    }
  }

  Future<void> _toggleMask(ChatGlobalMessage m) async {
    if (_isMasked(m)) {
      setState(() => _maskOverride[m.id] = false);
      return;
    }
    if (!_translations.containsKey(m.id)) await _translate(m);
    if (!mounted || !_translations.containsKey(m.id)) return;
    setState(() => _maskOverride[m.id] = true);
  }

  /// Та же пакетная загрузка, что в личном чате (см. `ChatThreadScreen`):
  /// только последние `_translateVisibleCount` сообщений и не те, что уже
  /// упали с ошибкой — иначе сотни сообщений разом шлют сотни запросов и
  /// то, что не переводится, пробуется бесконечно на каждый опрос сервера.
  void _autoTranslateIncoming() {
    if (!widget.prefs.autoTranslate) return;
    final from = _messages.length - _translateVisibleCount;
    for (var i = _messages.length - 1; i >= 0 && i >= from; i--) {
      final m = _messages[i];
      if (m.senderId == widget.auth.userId) continue;
      if (m.text == null || m.text!.isEmpty) continue;
      if (_translations.containsKey(m.id) || _translating.contains(m.id) || _translationErrors.containsKey(m.id)) {
        continue;
      }
      _translate(m, silent: true);
    }
  }

  void _copy(ChatGlobalMessage m) {
    if (m.text == null || m.text!.isEmpty) return;
    Clipboard.setData(ClipboardData(text: m.text!));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
  }

  void _reply(ChatGlobalMessage m) => setState(() => _replyingTo = m);

  /// Своё сообщение удаляется на сервере (RLS и так не даст чужое);
  /// чужое — только локально, "у себя" (решение пользователя, тот же
  /// принцип, что и в личном чате): список скрытых id хранится в
  /// `ChatPreferences`, само сообщение остаётся видимым остальным.
  Future<void> _delete(ChatGlobalMessage m) async {
    final mine = m.senderId == widget.auth.userId;
    if (!mine) {
      widget.prefs.hideGlobalMessage(m.id);
      setState(() => _messages.removeWhere((x) => x.id == m.id));
      return;
    }
    try {
      await widget.global.delete(m.id);
      setState(() => _messages.removeWhere((x) => x.id == m.id));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Маленькое окошко рядом с сообщением вместо листа снизу — те же
  /// действия, что в личном чате: копировать/ответить/перевести/удалить
  /// (решение пользователя).
  Future<void> _showMessageMenu(ChatGlobalMessage m, Offset at) async {
    final mine = m.senderId == widget.auth.userId;
    final canCopy = m.text != null && m.text!.isNotEmpty;
    final primary = Theme.of(context).colorScheme.primary;
    final action = await showChatQuickMenu(context, at, [
      if (canCopy) const ChatQuickAction(value: 'copy', icon: Icons.copy_outlined, label: 'Копировать'),
      const ChatQuickAction(value: 'reply', icon: Icons.reply_outlined, label: 'Ответить'),
      if (canCopy)
        ChatQuickAction(
          value: 'translate',
          icon: Icons.translate_outlined,
          label: 'Перевести',
          color: _isMasked(m) ? primary : null,
        ),
      ChatQuickAction(value: 'delete', icon: Icons.delete_outline, label: mine ? 'Удалить' : 'Удалить у себя'),
    ]);
    switch (action) {
      case 'copy':
        _copy(m);
      case 'reply':
        _reply(m);
      case 'translate':
        await _toggleMask(m);
      case 'delete':
        await _delete(m);
    }
  }

  Future<void> _load({bool silent = false}) async {
    // Крутилка — только если совсем нечего показать (первый вход без
    // кэша); если что-то уже нарисовано из _loadFromCache, обновление
    // происходит незаметно поверх него.
    if (!silent && _messages.isEmpty) setState(() => _loading = true);
    final messages = await widget.global.fetchRecent();
    if (!mounted) return;
    widget.repo.cacheGlobalMessages(messages);
    final hidden = widget.prefs.hiddenGlobalIds;
    setState(() {
      _messages = hidden.isEmpty ? messages : messages.where((m) => !hidden.contains(m.id)).toList();
      _loading = false;
    });
    _autoTranslateIncoming();
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
    final replyTo = _replyingTo;
    _input.clear();
    setState(() {
      _sending = true;
      _replyingTo = null;
    });
    try {
      await widget.global.send(
        text,
        replyToId: replyTo?.id,
        replyToPreview: replyTo == null ? null : ChatGlobalService.previewOf(replyTo),
      );
      await _load();
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Фото/файл в общую ленту (пункт 1 списка правок — раньше вложения
  /// умел только личный чат). Картинка сжимается перед загрузкой, как и
  /// в личном чате.
  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (!mounted) return;
    final file = result?.files.first;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    if (bytes.length > ChatMediaUtils.maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Слишком большой файл — до ${ChatMediaUtils.formatSize(ChatMediaUtils.maxAttachmentBytes)}'),
        ));
      }
      return;
    }

    final isImage = ChatMediaUtils.looksLikeImage(file.name);
    final caption = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => AttachmentComposeScreen(bytes: bytes, fileName: file.name, isImage: isImage),
    ));
    if (caption == null) return;

    setState(() => _sending = true);
    try {
      final compressed = isImage ? ChatMediaUtils.compressImage(bytes) : null;
      await widget.global.sendAttachment(
        bytes: compressed ?? bytes,
        fileName: file.name,
        mime: isImage ? (compressed != null ? 'image/jpeg' : ChatMediaUtils.mimeFor(file.name)) : 'application/octet-stream',
        caption: caption.isEmpty ? null : caption,
      );
      await _load();
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
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
                    // Уже в контактах — кнопка выглядит "нажатой" и больше
                    // не реагирует на тап (решение пользователя): убрать из
                    // контактов теперь отдельное действие, через меню (⋮)
                    // в самом чате с этим контактом, а не отсюда.
                    final isContact = widget.repo.contactById(p.senderId) != null;
                    return ListTile(
                      leading: ChatAvatar(base64: p.senderAvatarBase64, nickname: p.senderNickname ?? '?'),
                      title: Text(p.senderNickname ?? '—'),
                      trailing: isContact
                          ? const FilledButton(onPressed: null, child: Text('В контактах'))
                          : OutlinedButton(
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
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
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
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        return GestureDetector(
                          onLongPressStart: (d) => _showMessageMenu(m, d.globalPosition),
                          child: _GlobalBubble(
                            message: m,
                            mine: m.senderId == widget.auth.userId,
                            prefs: widget.prefs,
                            global: widget.global,
                            translation: _translations[m.id],
                            masked: _isMasked(m),
                            translating: _translating.contains(m.id),
                            translationError: _translationErrors[m.id],
                          ),
                        );
                      },
                    ),
        ),
        if (_replyingTo != null)
          ChatReplyBar(
            preview: ChatGlobalService.previewOf(_replyingTo!),
            onCancel: () => setState(() => _replyingTo = null),
          ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            // Ниже на ~10% (решение пользователя) — было 8 сверху/снизу.
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _sending ? null : _attach,
                  icon: const Icon(Icons.attach_file),
                  tooltip: 'Прикрепить фото или файл',
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(hintText: 'Сообщение всем', isDense: true),
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
  final ChatPreferences prefs;
  final ChatGlobalService global;
  final String? translation;
  final bool masked;
  final bool translating;
  final String? translationError;
  const _GlobalBubble({
    required this.message,
    required this.mine,
    required this.prefs,
    required this.global,
    required this.translation,
    required this.masked,
    required this.translating,
    required this.translationError,
  });

  static const double _imageMaxWidth = 260;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = mine ? prefs.mineBubbleColor : prefs.otherBubbleColor;
    final fg = mine ? prefs.mineTextColor : prefs.otherTextColor;
    final hasCaption = message.text != null && message.text!.isNotEmpty;
    // Фото без подписи — совсем без рамки/фона (тот же приём, что в
    // личном чате, см. _Bubble в chat_thread_screen.dart).
    final isBareImage = message.isImage && !hasCaption && message.replyToPreview == null;

    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(base, Colors.white, 0.08)!, Color.lerp(base, Colors.black, 0.10)!],
      ),
      boxShadow: prefs.shadowEnabled
          ? [BoxShadow(color: Colors.black.withValues(alpha: prefs.shadowIntensity), blurRadius: 10, offset: const Offset(0, 4))]
          : null,
    );

    final captionContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.replyToPreview != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: fg.withValues(alpha: 0.5), width: 3)),
            ),
            child: Text(
              message.replyToPreview!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: fg.withValues(alpha: 0.85)),
            ),
          ),
        if (message.hasAttachment && !message.isImage)
          _GlobalAttachment(message: message, global: global, fg: fg, showDownload: prefs.photoDownloadEnabled),
        if (translating)
          SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: fg.withValues(alpha: 0.7)),
          )
        else if (masked && translation != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 4),
                child: Icon(Icons.translate_outlined, size: 13, color: fg.withValues(alpha: 0.7)),
              ),
              Flexible(
                child: Text(translation!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ),
            ],
          )
        else if (hasCaption)
          // Text, не SelectableText — своё выделение перехватывало
          // долгое нажатие раньше меню действий (мешало открыть его
          // на Android). Копирование теперь только через меню.
          Text(message.text!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
      ],
    );

    final Widget frame;
    if (isBareImage) {
      frame = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
          child: _GlobalAttachment(
              message: message, global: global, fg: fg, bare: true, showDownload: prefs.photoDownloadEnabled),
        ),
      );
    } else if (message.isImage) {
      // Рамка только позади подписи, шириной ровно с фото — тот же
      // приём, что в личном чате.
      frame = IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
                child: _GlobalAttachment(
                    message: message, global: global, fg: fg, bare: true, showDownload: prefs.photoDownloadEnabled),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: decoration.copyWith(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16))),
              child: captionContent,
            ),
          ],
        ),
      );
    } else {
      frame = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: decoration.copyWith(borderRadius: BorderRadius.circular(16)),
        child: captionContent,
      );
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Отправитель — НАД пузырём, а не внутри (пункт 2 списка правок).
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 4),
              child: Text(
                message.senderNickname ?? '—',
                style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          frame,
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('HH:mm').format(message.createdAt.toLocal()),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
                if (translationError != null) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTapDown: (d) => showChatErrorBubble(context, d.globalPosition, translationError!),
                    child: const Icon(Icons.translate_outlined, size: 13, color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 5),
        ],
      ),
    );
  }
}

/// Вложение общего чата — бакет приватный, поэтому картинка грузится по
/// временной подписанной ссылке (см. `ChatGlobalService.signedUrl`), а
/// не напрямую по адресу объекта. Файл (не фото) открывается той же
/// ссылкой через системный обработчик — свою логику скачивания под
/// каждую платформу не пишем, `url_launcher` уже есть в проекте.
class _GlobalAttachment extends StatefulWidget {
  final ChatGlobalMessage message;
  final ChatGlobalService global;
  final Color fg;
  // true — без своей рамки/отступа снизу: обрезку и ширину задаёт
  // родитель (_GlobalBubble), сама картинка кладётся туда как есть.
  final bool bare;
  // "Скачивание фото и файлов" в настройках (ChatPreferences.photoDownloadEnabled).
  final bool showDownload;
  const _GlobalAttachment({
    required this.message,
    required this.global,
    required this.fg,
    this.bare = false,
    this.showDownload = false,
  });

  @override
  State<_GlobalAttachment> createState() => _GlobalAttachmentState();
}

class _GlobalAttachmentState extends State<_GlobalAttachment> {
  late final Future<String?> _urlFuture = widget.global.signedUrl(widget.message.attachmentPath!);

  /// В общем чате вложение живёт только в Storage (не как base64
  /// локально, в отличие от личного чата) — скачиваем по той же
  /// подписанной ссылке, что уже открыта на просмотр, и отдаём в
  /// системный лист "Поделиться".
  Future<void> _download(String url) async {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) return;
    await ChatMediaUtils.shareAttachment(
      res.bodyBytes,
      widget.message.attachmentName ?? (widget.message.isImage ? 'photo.jpg' : 'file'),
      widget.message.attachmentMime,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String?>(
      future: _urlFuture,
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (url == null) {
          return Text('Вложение недоступно', style: theme.textTheme.bodySmall?.copyWith(color: widget.fg));
        }
        if (widget.message.isImage) {
          final image = GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PhotoViewerScreen(image: NetworkImage(url)),
            )),
            child: Image.network(url, fit: widget.bare ? BoxFit.cover : BoxFit.contain),
          );
          final withButton = !widget.showDownload
              ? image
              : Stack(
                  children: [
                    image,
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _download(url),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.download_outlined, color: Colors.white, size: 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
          if (widget.bare) return withButton;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ClipRRect(borderRadius: BorderRadius.circular(10), child: withButton),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: InkWell(
                  onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.insert_drive_file_outlined, color: widget.fg),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${widget.message.attachmentName ?? 'Файл'} · ${ChatMediaUtils.formatSize(widget.message.attachmentSize)}',
                          style:
                              theme.textTheme.bodyMedium?.copyWith(color: widget.fg, decoration: TextDecoration.underline),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.showDownload) ...[
                const SizedBox(width: 4),
                InkWell(onTap: () => _download(url), child: Icon(Icons.download_outlined, color: widget.fg, size: 20)),
              ],
            ],
          ),
        );
      },
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
