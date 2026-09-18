import 'dart:convert';

import '../models/chat_contact.dart';
import '../models/chat_global_message.dart';
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

  /// Для перехода в нужную переписку по тапу на push-уведомление (см.
  /// `PushService`/`main.dart`) — там известен только id отправителя.
  ChatContact? contactById(String id) {
    final rows = db.db.select('SELECT * FROM chat_contacts WHERE id = ?', [id]);
    return rows.isEmpty ? null : ChatContact.fromRow(rows.first);
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
      'drive_file_id, attachment_local_path, '
      'reply_to_client_message_id, reply_to_preview, download_allowed, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
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
        m.driveFileId,
        m.attachmentLocalPath,
        m.replyToClientMessageId,
        m.replyToPreview,
        m.downloadAllowed ? 1 : 0,
        m.createdAt.toIso8601String(),
      ],
    );
  }

  void updateStatus(String id, ChatMessageStatus status) {
    db.db.execute('UPDATE chat_local_messages SET status = ? WHERE id = ?', [status.name, id]);
  }

  /// После успешной загрузки большого вложения на Drive — записать
  /// выданный id файла (см. `ChatSyncService.retryLargeAttachment`).
  void updateDriveFileId(String id, String driveFileId) {
    db.db.execute('UPDATE chat_local_messages SET drive_file_id = ? WHERE id = ?', [driveFileId, id]);
  }

  /// После скачивания большого вложения получателем — путь к файлу НА
  /// УСТРОЙСТВЕ (см. `ChatSyncService.downloadLargeAttachment`).
  void updateAttachmentLocalPath(String id, String path) {
    db.db.execute('UPDATE chat_local_messages SET attachment_local_path = ? WHERE id = ?', [path, id]);
  }

  /// "Иду"/отмена вызова (см. `ChatSyncService.acknowledgeCall`/`cancelCall`) —
  /// правит уже существующую `call`-строку, ту же самую и у отправителя,
  /// и (через сигнал) у получателя.
  void updateCallStatus(String id, String status) {
    db.db.execute('UPDATE chat_local_messages SET call_status = ? WHERE id = ?', [status, id]);
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

  /// Снимок последней успешно загруженной ленты общего чата — экран
  /// показывает его сразу при открытии, не дожидаясь сети (см.
  /// `_GlobalChatBodyState._load`), в отличие от личного чата тут это не
  /// история, а именно кэш: `cacheGlobalMessages` полностью его заменяет.
  /// Не должно уронить экран, если таблицы кэша вдруг ещё нет (например,
  /// на устройстве, где база создана до появления этой возможности, а
  /// миграция по какой-то причине до неё не докатилась) — тогда просто
  /// пустой кэш, экран покажет обычную крутилку вместо мгновенного показа.
  List<ChatGlobalMessage> cachedGlobalMessages() {
    try {
      final rows = db.db.select('SELECT * FROM chat_global_cache ORDER BY created_at');
      return rows
          .map((r) => ChatGlobalMessage.fromRow({
                'id': r['id'],
                'sender_id': r['sender_id'],
                'text': r['text'],
                'attachment_path': r['attachment_path'],
                'attachment_name': r['attachment_name'],
                'attachment_mime': r['attachment_mime'],
                'attachment_size': r['attachment_size'],
                'reply_to_id': r['reply_to_id'],
                'reply_to_preview': r['reply_to_preview'],
                'download_allowed': r['download_allowed'],
                'chart_json': r['chart_json'],
                'created_at': r['created_at'],
              }).withProfile(
                  nickname: r['sender_nickname'] as String?, avatarBase64: r['sender_avatar_base64'] as String?))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void cacheGlobalMessages(List<ChatGlobalMessage> messages) {
    try {
      db.db.execute('DELETE FROM chat_global_cache');
      for (final m in messages) {
        db.db.execute(
          'INSERT INTO chat_global_cache '
          '(id, sender_id, text, attachment_path, attachment_name, attachment_mime, attachment_size, '
          'reply_to_id, reply_to_preview, sender_nickname, sender_avatar_base64, download_allowed, chart_json, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            m.id,
            m.senderId,
            m.text,
            m.attachmentPath,
            m.attachmentName,
            m.attachmentMime,
            m.attachmentSize,
            m.replyToId,
            m.replyToPreview,
            m.senderNickname,
            m.senderAvatarBase64,
            m.downloadAllowed ? 1 : 0,
            m.chart == null ? null : jsonEncode(m.chart),
            m.createdAt.toIso8601String(),
          ],
        );
      }
    } catch (_) {
      // необязательно — просто не будет мгновенного показа в следующий раз
    }
  }
}
