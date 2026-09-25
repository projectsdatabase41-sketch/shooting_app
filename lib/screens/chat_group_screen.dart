import 'package:flutter/material.dart';

import '../logic/avatar_utils.dart';
import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_sync_service.dart';
import '../widgets/chat_avatar.dart';

/// Цвета оформления группы (аватар без фото, шапка переписки).
const List<String> chatGroupColors = [
  '', '#E53935', '#FB8C00', '#FDD835', '#43A047', '#00897B', '#1E88E5', '#5E35B1', '#D81B60', '#6D4C41',
];

String _roleLabel(String role) => switch (role) {
      'owner' => 'владелец',
      'admin' => 'админ',
      _ => '',
    };

/// Создание группы или правка её оформления: фото, название, описание,
/// цвет; при создании — выбор участников из контактов.
class ChatGroupEditScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;

  /// null — новая группа.
  final ChatContact? group;

  const ChatGroupEditScreen({super.key, required this.auth, required this.repo, required this.sync, this.group});

  @override
  State<ChatGroupEditScreen> createState() => _ChatGroupEditScreenState();
}

class _ChatGroupEditScreenState extends State<ChatGroupEditScreen> {
  late final _name = TextEditingController(text: widget.group?.nickname ?? '');
  late final _about = TextEditingController(text: widget.group?.about ?? '');
  late String _color = widget.group?.color ?? '';
  late String? _avatar = widget.group?.avatarBase64;
  final Set<String> _members = {};
  bool _busy = false;

  bool get _creating => widget.group == null;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Введите название')));
      return;
    }
    if (_creating && _members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Выберите хотя бы одного участника')));
      return;
    }
    setState(() => _busy = true);
    try {
      String id;
      if (_creating) {
        id = await widget.auth.createGroup(
          name: name,
          about: _about.text.trim(),
          color: _color,
          avatarBase64: _avatar,
          memberIds: _members.toList(),
        );
      } else {
        id = widget.group!.id;
        await widget.auth.updateGroup(id, name: name, about: _about.text.trim(), color: _color, avatarBase64: _avatar);
      }
      await widget.sync.syncGroups();
      if (mounted) Navigator.of(context).pop(widget.repo.contactById(id));
    } catch (e) {
      if (mounted) {
        final msg = '$e'.contains('create_group') || '$e'.contains('update_group')
            ? 'Группы ещё не включены на сервере — нужно выполнить sql/chat-groups.sql'
            : '$e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = widget.repo.listContacts().where((c) => !c.isGroup).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_creating ? 'Новая группа' : 'Изменить группу'),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: Text(_creating ? 'СОЗДАТЬ' : 'СОХРАНИТЬ')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: () async {
                final b64 = await AvatarUtils.pickAndProcess();
                if (b64 != null) setState(() => _avatar = b64);
              },
              child: Stack(
                children: [
                  ChatAvatar(
                    base64: _avatar,
                    nickname: _name.text.isEmpty ? '?' : _name.text,
                    radius: 44,
                    background: chatGroupColor(_color),
                  ),
                  const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 14, child: Icon(Icons.photo_camera, size: 16))),
                ],
              ),
            ),
          ),
          if (_avatar != null)
            Center(child: TextButton(onPressed: () => setState(() => _avatar = null), child: const Text('Убрать фото'))),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Название'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _about,
            maxLength: 200,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Описание (необязательно)'),
          ),
          const SizedBox(height: 8),
          Text('Цвет', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in chatGroupColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: chatGroupColor(c) ?? theme.colorScheme.surfaceContainerHighest,
                    child: _color == c
                        ? const Icon(Icons.check, color: Colors.white)
                        : (c.isEmpty ? const Icon(Icons.auto_awesome, size: 16) : null),
                  ),
                ),
            ],
          ),
          if (_creating) ...[
            const SizedBox(height: 20),
            Text('Участники (${_members.length})', style: theme.textTheme.titleSmall),
            if (contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Сначала добавьте людей в контакты: Контакты → «+»'),
              ),
            for (final c in contacts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                secondary: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                title: Text(c.nickname),
                subtitle: c.about.isEmpty ? null : Text(c.about, overflow: TextOverflow.ellipsis),
                value: _members.contains(c.id),
                onChanged: (v) => setState(() => v == true ? _members.add(c.id) : _members.remove(c.id)),
              ),
          ],
        ],
      ),
    );
  }
}

/// «О группе»: описание, участники с ролями, управление составом, выход.
class ChatGroupInfoScreen extends StatefulWidget {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatContact group;

  const ChatGroupInfoScreen({super.key, required this.auth, required this.repo, required this.sync, required this.group});

  @override
  State<ChatGroupInfoScreen> createState() => _ChatGroupInfoScreenState();
}

class _ChatGroupInfoScreenState extends State<ChatGroupInfoScreen> {
  late ChatContact _group = widget.group;
  bool _busy = false;

  String get _myRole => _group.member(widget.auth.userId)?.role ?? 'member';
  bool get _isAdmin => _myRole == 'owner' || _myRole == 'admin';

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await widget.sync.syncGroups();
      final fresh = widget.repo.contactById(_group.id);
      if (fresh != null && mounted) setState(() => _group = fresh);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMembers() async {
    final inGroup = _group.members.map((m) => m.id).toSet();
    final candidates = widget.repo.listContacts().where((c) => !c.isGroup && !inGroup.contains(c.id)).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Все ваши контакты уже в группе')));
      return;
    }
    final picked = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Добавить участников'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in candidates)
                  CheckboxListTile(
                    title: Text(c.nickname),
                    value: picked.contains(c.id),
                    onChanged: (v) => setLocal(() => v == true ? picked.add(c.id) : picked.remove(c.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Добавить')),
          ],
        ),
      ),
    );
    if (ok == true && picked.isNotEmpty) await _run(() => widget.auth.addGroupMembers(_group.id, picked.toList()));
  }

  Future<void> _memberActions(ChatGroupMember m) async {
    if (!_isAdmin || m.id == widget.auth.userId || m.role == 'owner') return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(m.nickname)),
            if (_myRole == 'owner')
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: Text(m.role == 'admin' ? 'Снять права админа' : 'Сделать админом'),
                onTap: () => Navigator.of(ctx).pop('role'),
              ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('Убрать из группы'),
              onTap: () => Navigator.of(ctx).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (action == 'role') {
      await _run(() => widget.auth.setGroupRole(_group.id, m.id, m.role == 'admin' ? 'member' : 'admin'));
    } else if (action == 'remove') {
      await _run(() => widget.auth.removeGroupMember(_group.id, m.id));
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из группы?'),
        content: const Text('Переписка останется на этом устройстве, но новых сообщений не будет.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.auth.removeGroupMember(_group.id, widget.auth.userId);
      widget.repo.deleteContact(_group.id);
      if (mounted) Navigator.of(context).pop('left');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = [..._group.members]
      ..sort((a, b) => ['owner', 'admin', 'member'].indexOf(a.role).compareTo(['owner', 'admin', 'member'].indexOf(b.role)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('О группе'),
        actions: [
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Изменить',
              onPressed: () async {
                final updated = await Navigator.of(context).push<ChatContact>(MaterialPageRoute(
                  builder: (_) => ChatGroupEditScreen(auth: widget.auth, repo: widget.repo, sync: widget.sync, group: _group),
                ));
                if (updated != null && mounted) setState(() => _group = updated);
              },
            ),
        ],
      ),
      body: ListView(
        children: [
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Center(
            child: ChatAvatar(
              base64: _group.avatarBase64,
              nickname: _group.nickname,
              radius: 44,
              background: chatGroupColor(_group.color),
            ),
          ),
          const SizedBox(height: 12),
          Center(child: Text(_group.nickname, style: theme.textTheme.titleLarge)),
          if (_group.about.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
              child: Text(_group.about, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            ),
          const SizedBox(height: 16),
          ListTile(
            title: Text('Участники: ${members.length}', style: theme.textTheme.titleSmall),
            trailing: _isAdmin
                ? IconButton(icon: const Icon(Icons.person_add_alt_outlined), tooltip: 'Добавить', onPressed: _addMembers)
                : null,
          ),
          for (final m in members)
            ListTile(
              leading: ChatAvatar(base64: widget.repo.contactById(m.id)?.avatarBase64, nickname: m.nickname),
              title: Text(m.id == widget.auth.userId ? '${m.nickname} (вы)' : m.nickname),
              trailing: Text(_roleLabel(m.role), style: theme.textTheme.bodySmall),
              onTap: () => _memberActions(m),
            ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('Выйти из группы', style: TextStyle(color: theme.colorScheme.error)),
            onTap: _busy ? null : _leave,
          ),
        ],
      ),
    );
  }
}
