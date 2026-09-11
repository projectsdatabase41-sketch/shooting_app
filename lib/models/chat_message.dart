enum ChatMessageDirection { outgoing, incoming }

/// `sending` — уходит на сервер прямо сейчас; `sent` — принято сервером;
/// `delivered` — прочитано (в MVP сервер удаляет строку сразу после
/// того, как получатель её забрал, — упрощение по сравнению с полным
/// циклом "прочитано/уведомление отправителю", см. `ChatSyncService`);
/// `error` — не ушло, нужна ручная отправка повторно.
enum ChatMessageStatus { sending, sent, delivered, error }

class ChatMessage {
  final String id;

  /// Для дедупликации при повторной отправке — тот же принцип, что
  /// обсуждался в чате с Qwen (`client_message_id`).
  final String clientMessageId;
  final String contactId;
  final ChatMessageDirection direction;
  final String text;
  final ChatMessageStatus status;

  /// Только для входящих — открыл ли получатель ветку с этим сообщением
  /// (см. комментарий у колонки `seen` в схеме).
  final bool seen;
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.clientMessageId,
    required this.contactId,
    required this.direction,
    required this.text,
    required this.status,
    this.seen = false,
    required this.createdAt,
  });

  ChatMessage copyWith({ChatMessageStatus? status, bool? seen}) => ChatMessage(
        id: id,
        clientMessageId: clientMessageId,
        contactId: contactId,
        direction: direction,
        text: text,
        status: status ?? this.status,
        seen: seen ?? this.seen,
        createdAt: createdAt,
      );

  factory ChatMessage.fromRow(Map<String, dynamic> row) => ChatMessage(
        id: row['id'] as String,
        clientMessageId: row['client_message_id'] as String,
        contactId: row['contact_id'] as String,
        direction: ChatMessageDirection.values.firstWhere((d) => d.name == row['direction']),
        text: row['text'] as String,
        status: ChatMessageStatus.values.firstWhere((s) => s.name == row['status']),
        seen: row['seen'] == 1 || row['seen'] == true,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
