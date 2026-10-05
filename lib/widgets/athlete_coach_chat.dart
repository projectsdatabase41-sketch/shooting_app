import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_contact.dart';
import '../screens/chat_thread_screen.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/coach_chat_link.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import 'call_coach_button.dart';
import 'coach_chat_view.dart';
import '../i18n/i18n.dart';

/// Вкладка «Тренер» на тренировке — чат прямо с тренером.
///
/// Тренер подключён к мессенджеру (связал чат-аккаунт с токеном — см.
/// `fetchLinkedCoachContacts`) — это полноценная переписка с вложениями и
/// push, а колокольчик «Вызвать тренера» стоит в её шапке. Не подключён
/// (или сам спортсмен не в мессенджере) — простой текстовый чат через
/// базу спортсмена (sql/coach-chat.sql), колокольчик при этом подскажет,
/// что для вызова нужен мессенджер.
class AthleteCoachChat extends StatefulWidget {
  const AthleteCoachChat({super.key});

  @override
  State<AthleteCoachChat> createState() => _AthleteCoachChatState();
}

class _AthleteCoachChatState extends State<AthleteCoachChat> {
  late final _db = context.read<AppDataStore>().db;
  late final ChatAuthService _chatAuth = ChatAuthService(_db);
  late final SupabaseAuthService _main = SupabaseAuthService(_db);
  late final ChatMessagesRepository _repo = ChatMessagesRepository(_db);
  late final ChatPreferences _prefs = ChatPreferences(_db);

  List<ChatContact>? _coaches;
  List<({String grantId, String name})>? _simple;
  String? _error;
  String? _selected;

  @override
  void initState() {
    super.initState();
    if (_main.isSignedIn) _load();
  }

  Future<void> _load() async {
    try {
      final contacts = _chatAuth.isSignedIn
          ? await fetchLinkedCoachContacts(_main, _chatAuth, _repo)
          : <ChatContact>[];
      final simple = contacts.isEmpty
          ? await _main.fetchChatCoaches()
          : <({String grantId, String name})>[];
      if (!mounted) return;
      setState(() {
        _coaches = contacts;
        _simple = simple;
        _error = null;
        _selected ??= contacts.isNotEmpty
            ? contacts.first.id
            : (simple.isEmpty ? null : simple.first.grantId);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Widget _hint(String text) => Center(
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text, textAlign: TextAlign.center)),
      );

  Widget _chips(List<({String id, String name})> items, String current) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: [
            for (final c in items)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(c.name),
                  selected: c.id == current,
                  onSelected: (_) => setState(() => _selected = c.id),
                ),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_main.isSignedIn) {
      return _hint(tr(
          'Чтобы переписываться с тренером, войдите в свою базу: Настройки → Учётная запись.'));
    }
    final coaches = _coaches;
    if (coaches == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : _hint(_error!);
    }

    if (coaches.isNotEmpty) {
      final current = coaches.firstWhere((c) => c.id == _selected,
          orElse: () => coaches.first);
      return Column(
        children: [
          if (coaches.length > 1)
            _chips([for (final c in coaches) (id: c.id, name: c.nickname)],
                current.id),
          Expanded(
            // Шапка переписки не должна добавлять отступ под строку состояния —
            // он уже учтён шапкой тренировки выше.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: ChatThreadScreen(
                key: ValueKey(current.id),
                embedded: true,
                contact: current,
                auth: _chatAuth,
                repo: _repo,
                sync: ChatSyncService(_chatAuth, _repo),
                prefs: _prefs,
              ),
            ),
          ),
        ],
      );
    }

    final simple = _simple ?? const [];
    if (simple.isEmpty) {
      return _hint(tr(
          'Тренер ещё не подключён — выдайте ему токен доступа: Настройки → Данные и синхронизация.'));
    }
    final current = simple.firstWhere((c) => c.grantId == _selected,
        orElse: () => simple.first);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: simple.length > 1
                    ? _chips(
                        [for (final c in simple) (id: c.grantId, name: c.name)],
                        current.grantId)
                    : Text(current.name,
                        style: Theme.of(context).textTheme.titleSmall),
              ),
              CallCoachButton(db: _db),
            ],
          ),
        ),
        Expanded(
          child: CoachChatView(
            key: ValueKey(current.grantId),
            myRole: 'athlete',
            otherLabel: current.name,
            load: () => _main.fetchCoachChat(current.grantId),
            send: (text) => _main.sendCoachChat(current.grantId, text),
            delete: _main.deleteCoachChat,
          ),
        ),
      ],
    );
  }
}
