/// Одно сообщение общего (всемирного) чата — в отличие от `ChatMessage`
/// (личная переписка, транзит-и-удаление), эти сообщения ХРАНЯТСЯ на
/// сервере и не привязаны к конкретному собеседнику: лента одна на всех
/// пользователей платформы. Локально не кешируется — экран просто
/// перечитывает последние N сообщений (см. `ChatGlobalService`).
class ChatGlobalMessage {
  final String id;
  final String senderId;
  final String text;
  final DateTime createdAt;

  /// Заполняются отдельным запросом (`resolve_profiles`) — сама лента
  /// отдаёт только `sender_id`, никнейм/аватар не хранятся построчно.
  final String? senderNickname;
  final String? senderAvatarBase64;

  const ChatGlobalMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.senderNickname,
    this.senderAvatarBase64,
  });

  ChatGlobalMessage withProfile({String? nickname, String? avatarBase64}) => ChatGlobalMessage(
        id: id,
        senderId: senderId,
        text: text,
        createdAt: createdAt,
        senderNickname: nickname ?? senderNickname,
        senderAvatarBase64: avatarBase64 ?? senderAvatarBase64,
      );

  factory ChatGlobalMessage.fromRow(Map<String, dynamic> row) => ChatGlobalMessage(
        id: '${row['id']}',
        senderId: '${row['sender_id']}',
        text: '${row['text']}',
        createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
      );
}
