import '../models/chat_contact.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'supabase_auth_service.dart';

/// Тренеры, которым выдан действующий токен И которые уже связали с ним
/// свой чат-аккаунт (sql/coach-chat-link.sql) — заодно заводит их в
/// контакты мессенджера. Общее между «Позвать тренера» и «Чатом с
/// тренером»: раньше у них были разные урезанные каналы, теперь оба
/// открывают один и тот же полноценный мессенджер-контакт (решение
/// пользователя, пункты 20/21/23 списка правок).
Future<List<ChatContact>> fetchLinkedCoachContacts(
  SupabaseAuthService main,
  ChatAuthService auth,
  ChatMessagesRepository repo,
) async {
  final linked = await main.fetchLinkedCoaches();
  final profiles =
      await auth.resolveProfiles([for (final c in linked) c.chatUserId]);
  final result = <ChatContact>[];
  for (final c in linked) {
    final existing = repo.contactById(c.chatUserId);
    final p = profiles[c.chatUserId];
    final contact = ChatContact(
      id: c.chatUserId,
      nickname: p?.nickname ?? (c.nickname.isNotEmpty ? c.nickname : c.label),
      chatCode: existing?.chatCode ?? '',
      avatarBase64: p?.avatarBase64 ?? existing?.avatarBase64,
      about: p?.about ?? existing?.about ?? '',
      addedAt: existing?.addedAt ?? DateTime.now(),
    );
    repo.addContact(contact);
    result.add(contact);
  }
  return result;
}
