import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import 'chat_group_screen.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';
import '../i18n/i18n.dart';

/// Друзья: входящие заявки (принять/отклонить), друзья (тап — чат, долгое
/// нажатие — выделение: в группу, звук, убрать из друзей) и свои заявки,
/// ждущие ответа. «+» — поиск по нику среди всех участников.
class ChatContactsScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;
  final void Function(ChatContact) onOpenThread;

  const ChatContactsScreen(
      {super.key,
      required this.auth,
      required this.repo,
      required this.sync,
      required this.prefs,
      required this.onOpenThread});

  @override
  State<ChatContactsScreen> createState() => _ChatContactsScreenState();
}

class _ChatContactsScreenState extends State<ChatContactsScreen> {
  final _search = TextEditingController();

  /// Связи с сервера: state — friend | incoming | outgoing.
  List<({String userId, String nickname, String? avatarBase64, String about, String state})>? _people;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.auth.friendOverview();
      // Друзья должны быть и в локальных контактах — оттуда открывается чат.
      for (final f in list.where((f) => f.state == 'friend')) {
        if (widget.repo.contactById(f.userId) == null) {
          widget.repo.addContact(ChatContact(
            id: f.userId,
            nickname: f.nickname,
            chatCode: '',
            avatarBase64: f.avatarBase64,
            about: f.about,
            addedAt: DateTime.now(),
          ));
        }
      }
      if (mounted) setState(() => (_people = list, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  /// Выделение: долгое нажатие — выделить, дальше тап добавляет/убирает.
  final Set<String> _selected = {};

  void _toggle(String id) => setState(() => _selected.remove(id) || _selected.add(id));

  /// В существующую группу (где я админ — иначе сервер откажет) или новую.
  Future<void> _addToGroup() async {
    final groups = widget.repo.listContacts().where((c) => c.isGroup).toList();
    final target = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: Text(tr('Новая группа')),
              onTap: () => Navigator.of(ctx).pop('new'),
            ),
            for (final g in groups)
              ListTile(
                leading: ChatAvatar(base64: g.avatarBase64, nickname: g.nickname, background: chatGroupColor(g.color)),
                title: Text(g.nickname),
                onTap: () => Navigator.of(ctx).pop(g),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    final ids = _selected.toList();
    if (target == 'new') {
      final group = await Navigator.of(context).push<ChatContact>(MaterialPageRoute(
        builder: (_) =>
            ChatGroupEditScreen(auth: widget.auth, repo: widget.repo, sync: widget.sync, initialMembers: ids.toSet()),
      ));
      if (!mounted) return;
      setState(() => _selected.clear());
      if (group != null) widget.onOpenThread(group);
      return;
    }
    final g = target as ChatContact;
    try {
      await widget.auth.addGroupMembers(g.id, ids);
      await widget.sync.syncGroups();
      if (!mounted) return;
      setState(() => _selected.clear());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Добавлено в «{nickname}»', {'nickname': g.nickname}))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Не получилось: {e}', {'e': e}))));
    }
  }

  void _toggleMute() {
    final allMuted = _selected.every(widget.prefs.mutedFor);
    for (final id in _selected) {
      widget.prefs.setMutedFor(id, !allMuted);
    }
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(allMuted ? tr('Уведомления включены') : tr('Уведомления выключены'))));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Убрать из друзей: {length}?', {'length': _selected.length})),
        content: Text(tr('Переписка останется, просто они больше не будут у вас в друзьях.')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Убрать'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final ids = _selected.toList();
    setState(() => _selected.clear());
    await _run(() async {
      for (final id in ids) {
        await widget.auth.removeFriend(id);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openDirectory() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatDirectoryScreen(auth: widget.auth, repo: widget.repo, onOpenThread: widget.onOpenThread),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _search.text.trim().toLowerCase();
    final people = (_people ?? const [])
        .where((p) => q.isEmpty || p.nickname.toLowerCase().contains(q) || p.about.toLowerCase().contains(q))
        .toList();
    final incoming = people.where((p) => p.state == 'incoming').toList();
    final friends = people.where((p) => p.state == 'friend').toList();
    final outgoing = people.where((p) => p.state == 'outgoing').toList();
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
        );
    final selecting = _selected.isNotEmpty;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected.clear());
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selected.clear())),
                title: Text('${_selected.length}'),
                actions: [
                  IconButton(icon: const Icon(Icons.group_add_outlined), tooltip: tr('В группу'), onPressed: _addToGroup),
                  IconButton(
                    icon: Icon(_selected.every(widget.prefs.mutedFor)
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined),
                    tooltip: tr('Уведомления'),
                    onPressed: _toggleMute,
                  ),
                  IconButton(icon: const Icon(Icons.person_remove_outlined), tooltip: tr('Убрать из друзей'), onPressed: _delete),
                ],
              )
            : AppBar(title: Text(tr('Друзья'))),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton(
                tooltip: tr('Найти участника'),
                onPressed: _openDirectory,
                child: const Icon(Icons.add),
              ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SearchBar(
                controller: _search,
                hintText: tr('Поиск среди друзей'),
                leading: const Icon(Icons.search),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: _people == null
                  ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                  : people.isEmpty
                      ? EmptyState(
                          icon: Icons.people_outline,
                          text: q.isEmpty
                              ? tr('Друзей пока нет — нажмите «+», найдите человека по нику и добавьте в друзья')
                              : tr('Никого не нашли'),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 88),
                            children: [
                              if (incoming.isNotEmpty) header(tr('Заявки в друзья ({n})', {'n': incoming.length})),
                              for (final p in incoming)
                                ListTile(
                                  leading: ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                                  title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                                  subtitle: p.about.isEmpty ? null : Text(p.about, overflow: TextOverflow.ellipsis),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: tr('Отклонить'),
                                        icon: const Icon(Icons.close),
                                        onPressed: () => _run(() => widget.auth.respondFriend(p.userId, false)),
                                      ),
                                      IconButton.filled(
                                        tooltip: tr('Принять'),
                                        icon: const Icon(Icons.check),
                                        onPressed: () => _run(() => widget.auth.respondFriend(p.userId, true)),
                                      ),
                                    ],
                                  ),
                                ),
                              if (friends.isNotEmpty) header(tr('Друзья ({n})', {'n': friends.length})),
                              for (final p in friends)
                                ListTile(
                                  selected: _selected.contains(p.userId),
                                  selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                                  leading: _selected.contains(p.userId)
                                      ? CircleAvatar(
                                          backgroundColor: theme.colorScheme.primary,
                                          child: Icon(Icons.check, color: theme.colorScheme.onPrimary),
                                        )
                                      : ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                                  title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                                  subtitle: p.about.isEmpty ? null : Text(p.about, overflow: TextOverflow.ellipsis),
                                  trailing: widget.prefs.mutedFor(p.userId)
                                      ? const Icon(Icons.notifications_off_outlined, size: 18)
                                      : null,
                                  onTap: selecting
                                      ? () => _toggle(p.userId)
                                      : () {
                                          final c = widget.repo.contactById(p.userId);
                                          if (c != null) widget.onOpenThread(c);
                                        },
                                  onLongPress: () => _toggle(p.userId),
                                ),
                              if (outgoing.isNotEmpty) header(tr('Ждут ответа ({n})', {'n': outgoing.length})),
                              for (final p in outgoing)
                                ListTile(
                                  leading: ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                                  title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(tr('заявка отправлена')),
                                  trailing: TextButton(
                                    onPressed: () => _run(() => widget.auth.removeFriend(p.userId)),
                                    child: Text(tr('Отменить')),
                                  ),
                                ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Все участники мессенджера — по алфавиту, подгрузка при прокрутке; поиск
/// ищет сразу по имени, «о себе» и точному коду контакта.
class ChatDirectoryScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final void Function(ChatContact) onOpenThread;

  const ChatDirectoryScreen({super.key, required this.auth, required this.repo, required this.onOpenThread});

  @override
  State<ChatDirectoryScreen> createState() => _ChatDirectoryScreenState();
}

class _ChatDirectoryScreenState extends State<ChatDirectoryScreen> {
  static const _page = 30;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final List<({String userId, String nickname, String? avatarBase64, String about})> _people = [];
  Timer? _debounce;
  bool _loading = false;
  bool _end = false;
  String? _error;
  int _generation = 0; // ответы на устаревший запрос отбрасываются

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
    });
    _reset();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _generation++;
    setState(() {
      _people.clear();
      _end = false;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _end) return;
    final gen = _generation;
    setState(() => _loading = true);
    try {
      final rows = await widget.auth.searchProfiles(_search.text, offset: _people.length, limit: _page);
      if (!mounted || gen != _generation) return;
      setState(() {
        _people.addAll(rows);
        _end = rows.length < _page;
      });
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  void _open(({String userId, String nickname, String? avatarBase64, String about}) p) {
    final contact = widget.repo.contactById(p.userId) ??
        ChatContact(
          id: p.userId,
          nickname: p.nickname,
          chatCode: '',
          avatarBase64: p.avatarBase64,
          about: p.about,
          addedAt: DateTime.now(),
        );
    widget.repo.addContact(contact);
    widget.onOpenThread(contact);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Все участники'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              controller: _search,
              autoFocus: true,
              hintText: tr('Ник или код контакта'),
              leading: const Icon(Icons.search),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), _reset);
              },
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!.contains('search_profiles')
                    ? tr('Поиск ещё не включён на сервере — нужно выполнить sql/chat-groups.sql')
                    : tr('Не удалось загрузить: {error}', {'error': _error}),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _people.isEmpty && !_loading && _error == null
                ? EmptyState(icon: Icons.person_search_outlined, text: tr('Никого не нашли'))
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _people.length + (_loading ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _people.length) {
                        return const Padding(
                            padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                      }
                      final p = _people[i];
                      return ListTile(
                        leading: ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                        title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                        subtitle: p.about.isEmpty ? null : Text(p.about, overflow: TextOverflow.ellipsis),
                        // Тап — написать; кнопка — заявка в друзья.
                        trailing: ChatAuthService.friendIds.contains(p.userId)
                            ? const Icon(Icons.how_to_reg, size: 20)
                            : IconButton(
                                tooltip: tr('Добавить в друзья'),
                                icon: const Icon(Icons.person_add_alt_1),
                                onPressed: () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  try {
                                    final r = await widget.auth.requestFriend(p.userId);
                                    messenger.showSnackBar(SnackBar(
                                      content: Text(switch (r) {
                                        'accepted' => tr('Теперь вы друзья'),
                                        'blocked' => tr('Нельзя: пользователь в чёрном списке'),
                                        _ => tr('Заявка в друзья отправлена'),
                                      }),
                                    ));
                                    if (mounted) setState(() {});
                                  } catch (e) {
                                    messenger.showSnackBar(SnackBar(content: Text('$e')));
                                  }
                                },
                              ),
                        onTap: () => _open(p),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
