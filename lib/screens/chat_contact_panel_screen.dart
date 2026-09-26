import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../widgets/chat_avatar.dart';
import 'chat_group_screen.dart';
import 'photo_viewer_screen.dart';
import '../i18n/i18n.dart';

/// Панель собеседника — открывается тапом по нику в шапке переписки
/// (как в Telegram): звонки, колокольчик, код, «о себе», дружба и всё,
/// что было в переписке, по вкладкам. Возвращает действие для переписки:
/// 'call', 'video', 'removed' (контакт удалён), 'left' (вышли из группы).
class ChatContactPanelScreen extends StatefulWidget {
  final ChatContact contact;
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;

  const ChatContactPanelScreen({
    super.key,
    required this.contact,
    required this.auth,
    required this.repo,
    required this.sync,
    required this.prefs,
  });

  @override
  State<ChatContactPanelScreen> createState() => _ChatContactPanelScreenState();
}

class _ChatContactPanelScreenState extends State<ChatContactPanelScreen> {
  late ChatContact _contact = widget.contact;
  late final List<ChatMessage> _messages = widget.repo.forContact(_contact.id).reversed.toList(); // новые сверху
  String _code = '';
  String? _friend; // 'accepted' | 'pending' | null
  bool _friendLoaded = false;

  static final _linkRe = RegExp(r'https?://[^\s<>()"]+', caseSensitive: false);

  @override
  void initState() {
    super.initState();
    _code = _contact.chatCode;
    if (!_contact.isGroup) {
      if (_code.isEmpty) widget.auth.codeOf(_contact.id).then((c) => mounted ? setState(() => _code = c) : null);
      widget.auth.friendStatusWith(_contact.id).then((s) {
        if (!mounted) return;
        setState(() {
          _friend = s;
          _friendLoaded = true;
        });
      });
    }
  }

  List<ChatMessage> get _photos =>
      _messages.where((m) => m.type == ChatMessageType.image && m.attachmentBase64 != null).toList();
  bool _isMusic(ChatMessage m) => m.type == ChatMessageType.file && ChatMediaUtils.looksLikeAudio(m.attachmentName ?? '');
  List<ChatMessage> get _files =>
      _messages.where((m) => (m.type == ChatMessageType.file || m.type == ChatMessageType.video) && !_isMusic(m)).toList();
  List<ChatMessage> get _music => _messages.where(_isMusic).toList();
  List<ChatMessage> get _voice => _messages.where((m) => m.type == ChatMessageType.audio).toList();
  List<(String, ChatMessage)> get _links => [
        for (final m in _messages)
          for (final match in _linkRe.allMatches(m.text ?? '')) (match.group(0)!, m),
      ];

  Future<void> _addFriend() async {
    await widget.auth.ensureFriendRequest(_contact.id);
    if (mounted) setState(() => _friend = 'pending');
  }

  Future<void> _removeContact() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить из контактов?')),
        content: Text(tr('Переписка с {nickname} останется на устройстве, но сам контакт пропадёт из списка.', {'nickname': _contact.nickname})),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Удалить'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.repo.deleteContact(_contact.id);
    Navigator.of(context).pop('removed');
  }

  Future<void> _openGroupInfo() async {
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => ChatGroupInfoScreen(auth: widget.auth, repo: widget.repo, sync: widget.sync, group: _contact),
    ));
    if (!mounted) return;
    if (result == 'left') {
      Navigator.of(context).pop('left');
      return;
    }
    setState(() => _contact = widget.repo.contactById(_contact.id) ?? _contact);
  }

  void _share(ChatMessage m) {
    if (m.attachmentBase64 != null) {
      ChatMediaUtils.shareAttachment(base64Decode(m.attachmentBase64!), m.attachmentName ?? 'file', m.attachmentMime);
    } else if (m.attachmentLocalPath != null) {
      ChatMediaUtils.shareAttachmentPath(m.attachmentLocalPath!, m.attachmentMime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = widget.prefs;
    final muted = prefs.mutedFor(_contact.id);
    final translate = prefs.autoTranslateFor(_contact.id);
    final tiles = <Widget>[
      if (!_contact.isGroup) ...[
        _Tile3D(icon: Icons.call, label: tr('Звонок'), onTap: () => Navigator.of(context).pop('call')),
        _Tile3D(icon: Icons.videocam, label: tr('Видео'), onTap: () => Navigator.of(context).pop('video')),
      ] else
        _Tile3D(icon: Icons.groups, label: tr('О группе'), onTap: _openGroupInfo),
      _Tile3D(
        icon: muted ? Icons.notifications_off : Icons.notifications_active,
        label: muted ? tr('Без звука') : tr('Звук'),
        active: !muted,
        onTap: () => setState(() => prefs.setMutedFor(_contact.id, !muted)),
      ),
      _Tile3D(
        icon: Icons.translate,
        label: tr('Перевод'),
        active: translate,
        onTap: () => setState(() => prefs.setAutoTranslateFor(_contact.id, !translate)),
      ),
    ];

    final header = Column(
      children: [
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
          ),
          child: ChatAvatar(
            base64: _contact.avatarBase64,
            nickname: _contact.nickname,
            radius: 46,
            background: _contact.isGroup ? chatGroupColor(_contact.color) : null,
          ),
        ),
        const SizedBox(height: 12),
        Text(_contact.nickname, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (_contact.isGroup)
          Text(tr('Участников: {length}', {'length': _contact.members.length}), style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [for (final t in tiles) Expanded(child: t)]),
        ),
        const SizedBox(height: 8),
        if (!_contact.isGroup)
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text(_code.isEmpty ? '—' : _code),
            subtitle: Text(tr('Код для поиска — нажмите, чтобы скопировать')),
            onTap: _code.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _code));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Код скопирован'))));
                  },
          ),
        if (_contact.about.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(_contact.about),
            subtitle: Text(_contact.isGroup ? tr('О группе') : tr('О себе')),
          ),
        if (!_contact.isGroup)
          ListTile(
            leading: Icon(_friend == 'accepted' ? Icons.how_to_reg : Icons.person_add_alt_1),
            title: Text(switch (_friend) {
              'accepted' => tr('В друзьях'),
              'pending' => tr('Заявка в друзья отправлена'),
              _ => _friendLoaded ? tr('Добавить в друзья') : '…',
            }),
            onTap: _friendLoaded && _friend == null ? _addFriend : null,
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (!_contact.isGroup)
            PopupMenuButton<String>(
              onSelected: (_) => _removeContact(),
              itemBuilder: (_) => [PopupMenuItem(value: 'remove', child: Text(tr('Удалить из контактов')))],
            ),
        ],
      ),
      body: DefaultTabController(
        length: 5,
        child: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(child: header),
            SliverAppBar(
              pinned: true,
              primary: false,
              automaticallyImplyLeading: false,
              toolbarHeight: 0,
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [Tab(text: tr('Фото')), Tab(text: tr('Файлы')), Tab(text: tr('Музыка')), Tab(text: tr('Ссылки')), Tab(text: tr('Голосовые'))],
              ),
            ),
          ],
          body: TabBarView(
            children: [
              _PhotoGrid(photos: _photos, prefs: prefs),
              _fileList(_files, Icons.insert_drive_file_outlined, tr('Файлов пока нет')),
              _fileList(_music, Icons.music_note_outlined, tr('Музыки пока нет')),
              _linkList(),
              _fileList(_voice, Icons.mic_none, tr('Голосовых пока нет')),
            ],
          ),
        ),
      ),
    );
  }

  static String _date(ChatMessage m) => DateFormat('dd.MM.yy HH:mm').format(m.createdAt.toLocal());

  Widget _empty(String text) => Center(child: Text(text, style: TextStyle(color: Theme.of(context).hintColor)));

  Widget _fileList(List<ChatMessage> items, IconData icon, String emptyText) {
    if (items.isEmpty) return _empty(emptyText);
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (_, i) {
        final m = items[i];
        return ListTile(
          leading: Icon(icon),
          title: Text(m.attachmentName ?? tr('Файл'), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${ChatMediaUtils.formatSize(m.attachmentSize)} · ${_date(m)}'),
          onTap: () => _share(m),
        );
      },
    );
  }

  Widget _linkList() {
    final links = _links;
    if (links.isEmpty) return _empty(tr('Ссылок пока нет'));
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: links.length,
      itemBuilder: (_, i) {
        final (url, m) = links[i];
        return ListTile(
          leading: const Icon(Icons.link),
          title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(_date(m)),
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Ссылка скопирована'))));
          },
        );
      },
    );
  }
}

/// Плитка-кнопка с объёмом: градиент, тень и наклон «от пальца» при нажатии.
class _Tile3D extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _Tile3D({required this.icon, required this.label, required this.onTap, this.active = true});

  @override
  State<_Tile3D> createState() => _Tile3DState();
}

class _Tile3DState extends State<_Tile3D> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.active ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = widget.active ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _down ? 1 : 0),
        duration: const Duration(milliseconds: 120),
        builder: (context, t, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateX(0.35 * t)
            ..scaleByDouble(1 - 0.05 * t, 1 - 0.05 * t, 1, 1),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(base, Colors.white, 0.12)!, Color.lerp(base, Colors.black, 0.12)!],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 10 - 6 * t,
                  offset: Offset(0, 6 - 4 * t),
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: Column(
          children: [
            Icon(widget.icon, color: fg),
            const SizedBox(height: 4),
            Text(widget.label, style: TextStyle(color: fg, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

/// Плитки фото, новые сверху. Щипок двумя пальцами — от 1 (лента) до 8
/// колонок; выбор общий для всех чатов и сохраняется.
class _PhotoGrid extends StatefulWidget {
  final List<ChatMessage> photos;
  final ChatPreferences prefs;
  const _PhotoGrid({required this.photos, required this.prefs});

  @override
  State<_PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<_PhotoGrid> {
  late int _cols = widget.prefs.mediaColumns;
  final Map<int, Offset> _pointers = {};
  double? _startDist;

  double _dist() {
    final p = _pointers.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) setState(() => _startDist = math.max(_dist(), 1));
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_startDist == null || _pointers.length < 2) return;
    final ratio = _dist() / _startDist!;
    // Развели пальцы — крупнее (меньше колонок), свели — мельче.
    final next = ratio > 1.25 ? _cols - 1 : (ratio < 0.8 ? _cols + 1 : _cols);
    if (next == _cols || next < 1 || next > 8) return;
    setState(() {
      _cols = next;
      _startDist = math.max(_dist(), 1);
    });
    widget.prefs.mediaColumns = next;
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _startDist != null) setState(() => _startDist = null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return Center(child: Text(tr('Фото пока нет'), style: TextStyle(color: Theme.of(context).hintColor)));
    }
    final physics = _startDist != null ? const NeverScrollableScrollPhysics() : null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width;
    Widget image(ChatMessage m, BoxFit fit) {
      final provider = ChatMediaUtils.imageOf(m.id, m.attachmentBase64!);
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhotoViewerScreen(image: provider))),
        child: Image(
          image: ResizeImage(provider, width: (width / _cols * dpr).round(), policy: ResizeImagePolicy.fit),
          fit: fit,
          gaplessPlayback: true,
        ),
      );
    }

    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _cols == 1
            ? ListView.separated(
                key: const ValueKey(1),
                physics: physics,
                padding: EdgeInsets.zero,
                itemCount: widget.photos.length,
                separatorBuilder: (_, __) => const SizedBox(height: 1),
                itemBuilder: (_, i) => image(widget.photos[i], BoxFit.fitWidth),
              )
            : GridView.builder(
                key: ValueKey(_cols),
                physics: physics,
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _cols,
                  mainAxisSpacing: 1,
                  crossAxisSpacing: 1,
                ),
                itemCount: widget.photos.length,
                // Фото целиком, без обрезки по квадрату (решение пользователя).
                itemBuilder: (_, i) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: image(widget.photos[i], BoxFit.contain),
                ),
              ),
      ),
    );
  }
}
