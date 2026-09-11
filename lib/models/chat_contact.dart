/// Собеседник в публичном чате. `id` — внутренний `user_id` из его
/// профиля в общей базе, известный ТОЛЬКО потому, что его отдал
/// `resolve_chat_code` при добавлении по коду — на экране нигде не
/// показывается (решение пользователя: скрыть внутренний ID, видимы
/// только никнейм и код контакта).
class ChatContact {
  final String id;
  final String nickname;
  final String chatCode;
  final String? avatarBase64;
  final DateTime addedAt;

  const ChatContact({
    required this.id,
    required this.nickname,
    required this.chatCode,
    this.avatarBase64,
    required this.addedAt,
  });

  factory ChatContact.fromRow(Map<String, dynamic> row) => ChatContact(
        id: row['id'] as String,
        nickname: row['nickname'] as String,
        chatCode: row['chat_code'] as String,
        avatarBase64: row['avatar_base64'] as String?,
        addedAt: DateTime.parse(row['added_at'] as String),
      );
}
