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
import 'chat_avatar.dart';
import '../i18n/i18n.dart';

/// «Чат с тренером» у спортсмена: тот же мессенджер-контакт, что у
/// «Позвать тренера» — полноценный чат с файлами, фото, push (решение
/// пользователя, пункты 20/21/23 списка правок: раньше это был
/// отдельный урезанный текстовый канал без вложений и уведомлений).
class AthleteCoachChat extends StatefulWidget {
  const AthleteCoachChat({super.key});

  @override
  State<AthleteCoachChat> createState() => _AthleteCoachChatState();
}

class _AthleteCoachChatState extends State<AthleteCoachChat> {
  late final ChatAuthService _chatAuth =
      ChatAuthService(context.read<AppDataStore>().db);
  late final SupabaseAuthService _main =
      SupabaseAuthService(context.read<AppDataStore>().db);
  late final ChatMessagesRepository _repo =
      ChatMessagesRepository(context.read<AppDataStore>().db);
  late final ChatPreferences _prefs =
      ChatPreferences(context.read<AppDataStore>().db);
  List<ChatContact>? _coaches;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_chatAuth.isSignedIn || !_main.isSignedIn) return;
    try {
      final list = await fetchLinkedCoachContacts(_main, _chatAuth, _repo);
      if (mounted) setState(() => (_coaches = list, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _open(ChatContact c) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatThreadScreen(
        contact: c,
        auth: _chatAuth,
        repo: _repo,
        sync: ChatSyncService(_chatAuth, _repo),
        prefs: _prefs,
      ),
    ));
  }

  Widget _hint(String text) => Center(
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text, textAlign: TextAlign.center)),
      );

  @override
  Widget build(BuildContext context) {
    if (!_chatAuth.isSignedIn) {
      return _hint(tr(
          'Сначала войдите в мессенджер — через него идёт переписка с тренером'));
    }
    if (!_main.isSignedIn) {
      return _hint(tr(
          'Войдите в свою базу (Настройки → Данные и синхронизация) — там выданы токены тренерам'));
    }
    final coaches = _coaches;
    if (coaches == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : _hint(_error!);
    }
    if (coaches.isEmpty) {
      return _hint(tr(
          'Тренер ещё не подключён: выдайте ему токен — он вводит его и открывает мессенджер'));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in coaches)
          Card(
            child: ListTile(
              leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
              title: Text(c.nickname),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(c),
            ),
          ),
      ],
    );
  }
}
