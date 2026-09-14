/// Одно сообщение общего (всемирного) чата — в отличие от `ChatMessage`
/// (личная переписка, транзит-и-удаление), эти сообщения ХРАНЯТСЯ на
/// сервере и не привязаны к конкретному собеседнику: лента одна на всех
/// пользователей платформы. Локально не кешируется — экран просто
/// перечитывает последние N сообщений (см. `ChatGlobalService`).
class ChatGlobalMessage {
  final String id;
  final String senderId;
  final String? text;
  final DateTime createdAt;

  /// Вложение (фото/файл) — путь в бакете chat-media (см.
  /// sql/chat-schema.sql, префикс "global/"), скачивается по требованию
  /// (ChatGlobalService.attachmentUrl), не хранится локально в отличие
  /// от личного чата (лента и так всегда живая).
  final String? attachmentPath;
  final String? attachmentName;
  final String? attachmentMime;
  final int? attachmentSize;

  /// Заполняются отдельным запросом (`resolve_profiles`) — сама лента
  /// отдаёт только `sender_id`, никнейм/аватар не хранятся построчно.
  final String? senderNickname;
  final String? senderAvatarBase64;

  const ChatGlobalMessage({
    required this.id,
    required this.senderId,
    this.text,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentName,
    this.attachmentMime,
    this.attachmentSize,
    this.senderNickname,
    this.senderAvatarBase64,
  });

  bool get hasAttachment => attachmentPath != null;

  bool get isImage {
    final mime = attachmentMime ?? '';
    return mime.startsWith('image/');
  }

  ChatGlobalMessage withProfile({String? nickname, String? avatarBase64}) => ChatGlobalMessage(
        id: id,
        senderId: senderId,
        text: text,
        createdAt: createdAt,
        attachmentPath: attachmentPath,
        attachmentName: attachmentName,
        attachmentMime: attachmentMime,
        attachmentSize: attachmentSize,
        senderNickname: nickname ?? senderNickname,
        senderAvatarBase64: avatarBase64 ?? senderAvatarBase64,
      );

  factory ChatGlobalMessage.fromRow(Map<String, dynamic> row) => ChatGlobalMessage(
        id: '${row['id']}',
        senderId: '${row['sender_id']}',
        text: row['text'] as String?,
        createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
        attachmentPath: row['attachment_path'] as String?,
        attachmentName: row['attachment_name'] as String?,
        attachmentMime: row['attachment_mime'] as String?,
        attachmentSize: (row['attachment_size'] as num?)?.toInt(),
      );
}
