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

/// Мои контакты (без групп) с поиском по списку. Кнопка «+» открывает всех
/// участников мессенджера — там же поиск по имени и по коду контакта.
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
              title: const Text('Новая группа'),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Добавлено в «${g.nickname}»')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не получилось: $e')));
    }
  }

  void _toggleMute() {
    final allMuted = _selected.every(widget.prefs.mutedFor);
    for (final id in _selected) {
      widget.prefs.setMutedFor(id, !allMuted);
    }
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(allMuted ? 'Уведомления включены' : 'Уведомления выключены')));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить из контактов: ${_selected.length}?'),
        content: const Text('Переписка останется на устройстве, пропадут только сами контакты.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final id in _selected) {
      widget.repo.deleteContact(id);
    }
    setState(() => _selected.clear());
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final contacts = widget.repo
        .listContacts()
        .where((c) => !c.isGroup)
        .where((c) => q.isEmpty || c.nickname.toLowerCase().contains(q) || c.about.toLowerCase().contains(q))
        .toList();
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
                  IconButton(icon: const Icon(Icons.group_add_outlined), tooltip: 'В группу', onPressed: _addToGroup),
                  IconButton(
                    icon: Icon(_selected.every(widget.prefs.mutedFor)
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined),
                    tooltip: 'Уведомления',
                    onPressed: _toggleMute,
                  ),
                  IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Удалить', onPressed: _delete),
                ],
              )
            : AppBar(title: const Text('Контакты')),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton(
                tooltip: 'Найти участника',
                onPressed: _openDirectory,
                child: const Icon(Icons.add),
              ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SearchBar(
                controller: _search,
                hintText: 'Поиск в контактах',
                leading: const Icon(Icons.search),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: contacts.isEmpty
                  ? EmptyState(
                      icon: Icons.people_outline,
                      text: q.isEmpty ? 'Контактов пока нет — нажмите «+», чтобы найти участника' : 'Никого не нашли',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        for (final c in contacts)
                          ListTile(
                            selected: _selected.contains(c.id),
                            selectedTileColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                            leading: _selected.contains(c.id)
                                ? CircleAvatar(
                                    backgroundColor: Theme.of(context).colorScheme.primary,
                                    child: Icon(Icons.check, color: Theme.of(context).colorScheme.onPrimary),
                                  )
                                : ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                            title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                            subtitle: c.about.isEmpty ? null : Text(c.about, overflow: TextOverflow.ellipsis),
                            trailing: widget.prefs.mutedFor(c.id)
                                ? const Icon(Icons.notifications_off_outlined, size: 18)
                                : null,
                            onTap: selecting ? () => _toggle(c.id) : () => widget.onOpenThread(c),
                            onLongPress: () => _toggle(c.id),
                          ),
                      ],
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
      appBar: AppBar(title: const Text('Все участники')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              controller: _search,
              autoFocus: true,
              hintText: 'Ник или код контакта',
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
                    ? 'Поиск ещё не включён на сервере — нужно выполнить sql/chat-groups.sql'
                    : 'Не удалось загрузить: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _people.isEmpty && !_loading && _error == null
                ? const EmptyState(icon: Icons.person_search_outlined, text: 'Никого не нашли')
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _people.length + (_loading ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _people.length) {
                        return const Padding(
                            padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                      }
                      final p = _people[i];
                      final known = widget.repo.contactById(p.userId) != null;
                      return ListTile(
                        leading: ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                        title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                        subtitle: p.about.isEmpty ? null : Text(p.about, overflow: TextOverflow.ellipsis),
                        trailing:
                            known ? const Icon(Icons.check, size: 18) : const Icon(Icons.chat_bubble_outline, size: 18),
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
