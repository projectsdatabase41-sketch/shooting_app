import 'package:flutter/material.dart';

import '../models/chat_contact.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/local_db_service.dart';
import '../services/supabase_auth_service.dart';
import 'chat_avatar.dart';
import '../i18n/i18n.dart';

/// «Позвать тренера» — на экране тренировки. Тренер — тот, кому спортсмен
/// выдал токен доступа: подключившись, тренер связывает с токеном свой
/// чат-аккаунт (sql/coach-chat-link.sql, `CoachAccessService.linkChat`).
/// Тренеров несколько — выбор запоминается, долгое нажатие меняет его.
class CallCoachButton extends StatefulWidget {
  final LocalDbService db;

  /// Большая кнопка с подписью (страница «Тренер» на тренировке), иначе — значок.
  final bool large;
  const CallCoachButton({super.key, required this.db, this.large = false});

  @override
  State<CallCoachButton> createState() => _CallCoachButtonState();
}

class _CallCoachButtonState extends State<CallCoachButton> {
  late final ChatAuthService _auth = ChatAuthService(widget.db);
  late final SupabaseAuthService _main = SupabaseAuthService(widget.db);
  late final ChatMessagesRepository _repo = ChatMessagesRepository(widget.db);
  late final ChatPreferences _prefs = ChatPreferences(widget.db);
  bool _busy = false;

  /// Тренеры из токенов; заодно заводит их в контакты мессенджера.
  Future<List<ChatContact>> _coaches() async {
    final linked = await _main.fetchLinkedCoaches();
    final profiles = await _auth.resolveProfiles([for (final c in linked) c.chatUserId]);
    final result = <ChatContact>[];
    for (final c in linked) {
      final existing = _repo.contactById(c.chatUserId);
      final p = profiles[c.chatUserId];
      final contact = ChatContact(
        id: c.chatUserId,
        nickname: p?.nickname ?? (c.nickname.isNotEmpty ? c.nickname : c.label),
        chatCode: existing?.chatCode ?? '',
        avatarBase64: p?.avatarBase64 ?? existing?.avatarBase64,
        about: p?.about ?? existing?.about ?? '',
        addedAt: existing?.addedAt ?? DateTime.now(),
      );
      _repo.addContact(contact);
      result.add(contact);
    }
    return result;
  }

  Future<String?> _pick(List<ChatContact> coaches) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(tr('Кого позвать?'))),
            for (final c in coaches)
              ListTile(
                leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                title: Text(c.nickname),
                subtitle: c.about.isEmpty ? null : Text(c.about),
                trailing: c.id == _prefs.coachContactId ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(c.id),
              ),
          ],
        ),
      ),
    );
    if (id != null) _prefs.coachContactId = id;
    return id;
  }

  Future<void> _call({bool choose = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_auth.isSignedIn) {
      messenger.showSnackBar(SnackBar(
        content: Text(tr('Сначала войдите в мессенджер — через него тренер получит вызов')),
      ));
      return;
    }
    if (!_main.isSignedIn) {
      messenger.showSnackBar(SnackBar(
        content: Text(tr('Войдите в свою базу (Настройки → Данные и синхронизация) — там выданы токены тренерам')),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      final coaches = await _coaches();
      if (coaches.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(tr('Тренер ещё не подключён: выдайте ему токен — он вводит его и открывает мессенджер')),
        ));
        return;
      }
      var id = _prefs.coachContactId;
      if (coaches.length == 1) {
        id = coaches.single.id;
      } else if (choose || !coaches.any((c) => c.id == id)) {
        if (!mounted) return;
        id = await _pick(coaches) ?? '';
      }
      if (id.isEmpty) return;
      await ChatSyncService(_auth, _repo).sendCall(id);
      messenger.showSnackBar(SnackBar(content: Text(tr('{p} получит вызов', {'p': _repo.contactById(id)?.nickname ?? tr('Тренер')}))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Не удалось позвать: {e}', {'e': e}))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.large) {
      return GestureDetector(
        onLongPress: _busy ? null : () => _call(choose: true),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _call,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.campaign_outlined),
          label: Text(tr('Позвать тренера')),
        ),
      );
    }
    return GestureDetector(
      onLongPress: _busy ? null : () => _call(choose: true),
      child: IconButton(
        icon: _busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.campaign_outlined),
        tooltip: tr('Позвать тренера'),
        onPressed: _busy ? null : _call,
      ),
    );
  }
}
