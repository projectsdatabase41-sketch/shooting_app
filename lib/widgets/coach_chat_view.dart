import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/coach_chat_message.dart';
import '../services/chat_preferences.dart';
import '../state/app_data_store.dart';
import 'glass_pill.dart';
import 'messenger_bubble.dart';

/// Переписка «спортсмен ↔ тренер» (sql/coach-chat.sql) — одна и та же
/// лента у обеих сторон, различаются только функции загрузки/отправки.
/// Новое подтягивается опросом раз в 10 с, пока экран открыт. Сменили
/// собеседника — родитель меняет `key`, лента создаётся заново.
class CoachChatView extends StatefulWidget {
  /// 'athlete' или 'coach' — чьи сообщения справа.
  final String myRole;

  /// Подпись у сообщений собеседника («Тренер» / имя спортсмена).
  final String otherLabel;
  final Future<List<CoachChatMessage>> Function() load;
  final Future<void> Function(String text) send;
  final Future<void> Function(String id) delete;

  const CoachChatView({
    super.key,
    required this.myRole,
    required this.otherLabel,
    required this.load,
    required this.send,
    required this.delete,
  });

  @override
  State<CoachChatView> createState() => _CoachChatViewState();
}

class _CoachChatViewState extends State<CoachChatView> {
  final _input = TextEditingController();
  List<CoachChatMessage>? _messages;
  String? _error;
  bool _sending = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final list = await widget.load();
      if (!mounted) return;
      setState(() {
        _messages = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.send(text);
      _input.clear();
      await _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _actions(CoachChatMessage m, bool mine) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать'),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: m.text));
              },
            ),
            if (mine)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('Удалить', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Удалить сообщение?'),
                      content: const Text('Удалится и у собеседника.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Отмена')),
                        FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Удалить')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await widget.delete(m.id);
                    await _reload();
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ChatPreferences(context.read<AppDataStore>().db);
    final df = DateFormat('dd.MM HH:mm');
    final messages = _messages;
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: messages == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
                )
              : messages.isEmpty
                  ? const Center(child: Text('Сообщений пока нет'))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final m = messages[messages.length - 1 - i];
                        final mine = m.authorRole == widget.myRole;
                        return MessengerBubble(
                          text: m.text,
                          author: mine ? null : widget.otherLabel,
                          mine: mine,
                          prefs: prefs,
                          time: df.format(m.createdAt),
                          onLongPress: () => _actions(m, mine),
                        );
                      },
                    ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: GlassPill(
                  radius: 25,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Сообщение…',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassCircleButton(
                size: 50,
                tooltip: 'Отправить',
                color: cs.primary.withValues(alpha: 0.85),
                onTap: _sending ? null : _send,
                icon: _sending
                    ? SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                    : Icon(Icons.send, color: cs.onPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
