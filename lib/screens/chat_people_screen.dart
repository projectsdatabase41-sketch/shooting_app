import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';

/// Мои контакты (без групп) с поиском по списку. Кнопка «+» открывает всех
/// участников мессенджера — там же поиск по имени и по коду контакта.
class ChatContactsScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final void Function(ChatContact) onOpenThread;

  const ChatContactsScreen({super.key, required this.auth, required this.repo, required this.onOpenThread});

  @override
  State<ChatContactsScreen> createState() => _ChatContactsScreenState();
}

class _ChatContactsScreenState extends State<ChatContactsScreen> {
  final _search = TextEditingController();

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
    return Scaffold(
      appBar: AppBar(title: const Text('Контакты')),
      floatingActionButton: FloatingActionButton(
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
                          leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                          title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                          subtitle: c.about.isEmpty ? null : Text(c.about, overflow: TextOverflow.ellipsis),
                          onTap: () => widget.onOpenThread(c),
                        ),
                    ],
                  ),
          ),
        ],
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
              hintText: 'Имя или код контакта',
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
                        return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                      }
                      final p = _people[i];
                      final known = widget.repo.contactById(p.userId) != null;
                      return ListTile(
                        leading: ChatAvatar(base64: p.avatarBase64, nickname: p.nickname),
                        title: Text(p.nickname, overflow: TextOverflow.ellipsis),
                        subtitle: p.about.isEmpty ? null : Text(p.about, overflow: TextOverflow.ellipsis),
                        trailing: known ? const Icon(Icons.check, size: 18) : const Icon(Icons.chat_bubble_outline, size: 18),
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
