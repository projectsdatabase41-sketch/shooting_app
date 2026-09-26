import 'package:flutter/material.dart';

import '../services/coach_access_service.dart';
import '../widgets/coach_chat_view.dart';
import '../widgets/glass_pill.dart';

/// «Чат со спортсменами» у тренера (плитка в «Спортсменах»): тап —
/// переписка с одним, долгое нажатие — выделить нескольких и написать
/// всем сразу (каждому уходит своё сообщение в его «Чат с тренером»).
class CoachAthletesChatScreen extends StatefulWidget {
  final CoachAccessService access;
  const CoachAthletesChatScreen({super.key, required this.access});

  @override
  State<CoachAthletesChatScreen> createState() => _CoachAthletesChatScreenState();
}

class _CoachAthletesChatScreenState extends State<CoachAthletesChatScreen> {
  late final List<CoachAthlete> _athletes = widget.access.listAthletes();
  final Set<String> _selected = {};

  void _toggle(String id) => setState(() => _selected.remove(id) || _selected.add(id));

  Future<void> _writeToSelected() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Сообщение: ${_selected.length} спортсм.'),
        content: TextField(controller: ctrl, autofocus: true, minLines: 2, maxLines: 6),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Отправить')),
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
          ? 'Отправлено: ${targets.length}'
          : 'Не отправлено: ${failed.join(', ')} (нет связи или в базе спортсмена не выполнен sql/coach-chat.sql)'),
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
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selected.clear())),
                title: Text('${_selected.length}'),
                actions: [
                  IconButton(icon: const Icon(Icons.send), tooltip: 'Написать выбранным', onPressed: _writeToSelected),
                ],
              )
            : GlassHeader(
                title: Text('Чат со спортсменами',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
        body: _athletes.isEmpty
            ? const Center(child: Text('Спортсменов пока нет'))
            : ListView(
                children: [
                  for (final a in _athletes)
                    ListTile(
                      selected: _selected.contains(a.id),
                      selectedTileColor: cs.primary.withValues(alpha: 0.12),
                      leading: CircleAvatar(
                        backgroundColor: _selected.contains(a.id) ? cs.primary : cs.primaryContainer,
                        child: _selected.contains(a.id)
                            ? Icon(Icons.check, color: cs.onPrimary)
                            : Text(a.name.isEmpty ? '?' : a.name[0].toUpperCase(),
                                style: TextStyle(color: cs.onPrimaryContainer)),
                      ),
                      title: Text(a.name),
                      onTap: selecting
                          ? () => _toggle(a.id)
                          : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CoachAthleteChatScreen(access: widget.access, athlete: a),
                              )),
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
  const CoachAthleteChatScreen({super.key, required this.access, required this.athlete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassHeader(
        title: Text(athlete.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
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
