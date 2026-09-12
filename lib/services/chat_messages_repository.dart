import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import 'local_db_service.dart';

/// Локальное хранилище чата — контакты и история переписки живут ТОЛЬКО
/// на устройстве (см. `chat_settings.dart`), сервер лишь передаёт
/// сообщения транзитом.
class ChatMessagesRepository {
  final LocalDbService db;
  ChatMessagesRepository(this.db);

  List<ChatContact> listContacts() {
    final rows = db.db.select('SELECT * FROM chat_contacts ORDER BY nickname');
    return rows.map(ChatContact.fromRow).toList();
  }

  void addContact(ChatContact c) {
    db.db.execute(
      'INSERT INTO chat_contacts (id, nickname, chat_code, avatar_base64) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET nickname = excluded.nickname, chat_code = excluded.chat_code, '
      'avatar_base64 = excluded.avatar_base64',
      [c.id, c.nickname, c.chatCode, c.avatarBase64],
    );
  }

  void deleteContact(String id) {
    db.db.execute('DELETE FROM chat_contacts WHERE id = ?', [id]);
  }

  List<ChatMessage> forContact(String contactId) {
    final rows = db.db.select(
      'SELECT * FROM chat_local_messages WHERE contact_id = ? ORDER BY created_at',
      [contactId],
    );
    return rows.map(ChatMessage.fromRow).toList();
  }

  /// Последнее сообщение переписки — для превью в списке контактов.
  ChatMessage? lastForContact(String contactId) {
    final rows = db.db.select(
      'SELECT * FROM chat_local_messages WHERE contact_id = ? ORDER BY created_at DESC LIMIT 1',
      [contactId],
    );
    return rows.isEmpty ? null : ChatMessage.fromRow(rows.first);
  }

  void addMessage(ChatMessage m) {
    db.db.execute(
      'INSERT INTO chat_local_messages '
      '(id, client_message_id, contact_id, direction, text, status, msg_type, '
      'attachment_base64, attachment_name, attachment_mime, attachment_size, '
      'reply_to_client_message_id, reply_to_preview, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        m.id,
        m.clientMessageId,
        m.contactId,
        m.direction.name,
        m.text,
        m.status.name,
        m.type.name,
        m.attachmentBase64,
        m.attachmentName,
        m.attachmentMime,
        m.attachmentSize,
        m.replyToClientMessageId,
        m.replyToPreview,
        m.createdAt.toIso8601String(),
      ],
    );
  }

  void updateStatus(String id, ChatMessageStatus status) {
    db.db.execute('UPDATE chat_local_messages SET status = ? WHERE id = ?', [status.name, id]);
  }

  /// Находит локальное сообщение этой переписки по `client_message_id` —
  /// нужно, чтобы применить входящий edit/delete-сигнал (см.
  /// `ChatSyncService.pollIncoming`) к уже сохранённой строке.
  ChatMessage? byClientId(String contactId, String clientMessageId) {
    final rows = db.db.select(
      'SELECT * FROM chat_local_messages WHERE contact_id = ? AND client_message_id = ? LIMIT 1',
      [contactId, clientMessageId],
    );
    return rows.isEmpty ? null : ChatMessage.fromRow(rows.first);
  }

  /// Правка текста задним числом — своя (сразу после отправки edit-
  /// сигнала) или пришедшая от собеседника.
  void updateText(String id, String text) {
    db.db.execute('UPDATE chat_local_messages SET text = ?, edited = 1 WHERE id = ?', [text, id]);
  }

  void deleteMessage(String id) {
    db.db.execute('DELETE FROM chat_local_messages WHERE id = ?', [id]);
  }

  /// Сколько непрочитанных входящих у контакта — бейдж в списке.
  int unreadCount(String contactId) {
    final rows = db.db.select(
      "SELECT COUNT(*) AS n FROM chat_local_messages WHERE contact_id = ? AND direction = 'incoming' AND seen = 0",
      [contactId],
    );
    return rows.isEmpty ? 0 : (rows.first['n'] as int);
  }

  /// Открыли ветку с контактом — все его входящие считаются прочитанными
  /// (сервер к этому моменту уже ничего не хранит, это чисто локальная
  /// отметка).
  void markThreadSeen(String contactId) {
    db.db.execute(
      "UPDATE chat_local_messages SET seen = 1 WHERE contact_id = ? AND direction = 'incoming' AND seen = 0",
      [contactId],
    );
  }

  bool existsByClientId(String clientMessageId) {
    final rows = db.db.select(
      'SELECT 1 FROM chat_local_messages WHERE client_message_id = ? LIMIT 1',
      [clientMessageId],
    );
    return rows.isNotEmpty;
  }
}
