import 'package:flutter/material.dart';

import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/coach_access_service.dart';
import 'chat_thread_screen.dart';
import '../widgets/coach_chat_view.dart';
import '../widgets/glass_pill.dart';
import '../i18n/i18n.dart';

/// «Чат со спортсменами» у тренера (плитка в «Спортсменах»): тап —
/// переписка с одним, долгое нажатие — выделить нескольких и написать
/// всем сразу (каждому уходит своё сообщение в его «Чат с тренером»).
class CoachAthletesChatScreen extends StatefulWidget {
  final CoachAccessService access;
  const CoachAthletesChatScreen({super.key, required this.access});

  @override
  State<CoachAthletesChatScreen> createState() =>
      _CoachAthletesChatScreenState();
}

class _CoachAthletesChatScreenState extends State<CoachAthletesChatScreen> {
  late final List<CoachAthlete> _athletes = widget.access.listAthletes();
  final Set<String> _selected = {};

  void _toggle(String id) =>
      setState(() => _selected.remove(id) || _selected.add(id));

  /// Открывает полноценный мессенджер-чат со спортсменом вместо старого
  /// урезанного канала — связывает чат-аккаунты по токену (как уже
  /// делает `CallCoachButton` со стороны спортсмена) и заводит контакт
  /// (решение пользователя, пункты 20/21/23 списка правок). Не вышло
  /// (нет сети, спортсмен ещё не заходил в мессенджер) — старый канал
  /// как резерв, чтобы переписка не пропадала совсем.
  Future<void> _open(CoachAthlete a) async {
    final chatAuth = ChatAuthService(widget.access.db);
    if (chatAuth.isSignedIn) {
      try {
        final link = await widget.access.linkChat(a,
            chatUserId: chatAuth.userId, nickname: chatAuth.nickname);
        if (link != null) {
          final repo = ChatMessagesRepository(widget.access.db);
          final existing = repo.contactById(link.chatUserId);
          final contact = ChatContact(
            id: link.chatUserId,
            nickname: link.nickname.isNotEmpty ? link.nickname : a.name,
            chatCode: existing?.chatCode ?? '',
            avatarBase64: existing?.avatarBase64,
            about: existing?.about ?? '',
            addedAt: existing?.addedAt ?? DateTime.now(),
          );
          repo.addContact(contact);
          if (!mounted) return;
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatThreadScreen(
              contact: contact,
              auth: chatAuth,
              repo: repo,
              sync: ChatSyncService(chatAuth, repo),
              prefs: ChatPreferences(widget.access.db),
            ),
          ));
          return;
        }
      } catch (_) {
        // сеть/спортсмен без мессенджера — падём на старый канал ниже
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CoachAthleteChatScreen(access: widget.access, athlete: a),
    ));
  }

  Future<void> _writeToSelected() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            tr('Сообщение: {length} спортсм.', {'length': _selected.length})),
        content: TextField(
            controller: ctrl, autofocus: true, minLines: 2, maxLines: 6),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(tr('Отправить'))),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    final targets = _athletes.where((a) => _selected.contains(a.id)).toList();
    final failed = <String>[];
    for (final a in targets) {
      try {
        await widget.access.sendCoachChat(a, text);
      } catch (_) {
        failed.add(a.name);
      }
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(failed.isEmpty
          ? tr('Отправлено: {length}', {'length': targets.length})
          : tr(
              'Не отправлено: {p} (нет связи или в базе спортсмена не выполнен sql/coach-chat.sql)',
              {'p': failed.join(', ')})),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected.clear());
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _selected.clear())),
                title: Text('${_selected.length}'),
                actions: [
                  IconButton(
                      icon: const Icon(Icons.send),
                      tooltip: tr('Написать выбранным'),
                      onPressed: _writeToSelected),
                ],
              )
            : GlassHeader(
                title: Text(tr('Чат со спортсменами'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
        body: _athletes.isEmpty
            ? Center(child: Text(tr('Спортсменов пока нет')))
            : ListView(
                children: [
                  for (final a in _athletes)
                    ListTile(
                      selected: _selected.contains(a.id),
                      selectedTileColor: cs.primary.withValues(alpha: 0.12),
                      leading: CircleAvatar(
                        backgroundColor: _selected.contains(a.id)
                            ? cs.primary
                            : cs.primaryContainer,
                        child: _selected.contains(a.id)
                            ? Icon(Icons.check, color: cs.onPrimary)
                            : Text(
                                a.name.isEmpty ? '?' : a.name[0].toUpperCase(),
                                style: TextStyle(color: cs.onPrimaryContainer)),
                      ),
                      title: Text(a.name),
                      onTap: selecting ? () => _toggle(a.id) : () => _open(a),
                      onLongPress: () => _toggle(a.id),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Переписка тренера с одним спортсменом.
class CoachAthleteChatScreen extends StatelessWidget {
  final CoachAccessService access;
  final CoachAthlete athlete;
  const CoachAthleteChatScreen(
      {super.key, required this.access, required this.athlete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassHeader(
        title: Text(athlete.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        top: false,
        child: CoachChatView(
          myRole: 'coach',
          otherLabel: athlete.name,
          load: () => access.fetchCoachChat(athlete),
          send: (text) => access.sendCoachChat(athlete, text),
          delete: (id) => access.deleteCoachChat(athlete, id),
        ),
      ),
    );
  }
}
