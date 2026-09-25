import 'dart:convert';

/// Участник группы (из `my_groups` на сервере).
class ChatGroupMember {
  final String id;
  final String nickname;
  final String role; // owner | admin | member
  const ChatGroupMember({required this.id, required this.nickname, this.role = 'member'});

  Map<String, dynamic> toJson() => {'id': id, 'nickname': nickname, 'role': role};
  factory ChatGroupMember.fromJson(Map<String, dynamic> j) =>
      ChatGroupMember(id: '${j['id']}', nickname: '${j['nickname'] ?? '—'}', role: '${j['role'] ?? 'member'}');
}

/// Собеседник в личном чате — или группа. Группа хранится той же строкой
/// `chat_contacts` (kind = 'group'): так список диалогов, непрочитанные и
/// история переписки работают для неё без отдельного кода.
class ChatContact {
  final String id;
  final String nickname;
  final String chatCode;
  final String? avatarBase64;

  /// Короткая строка о человеке (клуб, город, дисциплина) — чтобы отличать
  /// тёзок, когда нет фото. У группы — её описание.
  final String about;
  final DateTime addedAt;

  final bool isGroup;

  /// Только у групп: участники и цвет оформления (hex, пусто — по умолчанию).
  final List<ChatGroupMember> members;
  final String color;

  const ChatContact({
    required this.id,
    required this.nickname,
    required this.chatCode,
    this.avatarBase64,
    this.about = '',
    required this.addedAt,
    this.isGroup = false,
    this.members = const [],
    this.color = '',
  });

  ChatGroupMember? member(String userId) {
    for (final m in members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  String get groupJson => jsonEncode({'members': [for (final m in members) m.toJson()], 'color': color});

  factory ChatContact.fromRow(Map<String, dynamic> row) {
    final isGroup = row['kind'] == 'group';
    var members = const <ChatGroupMember>[];
    var color = '';
    final raw = row['group_json'] as String?;
    if (isGroup && raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        members = [for (final m in (j['members'] as List? ?? const [])) ChatGroupMember.fromJson(Map<String, dynamic>.from(m as Map))];
        color = '${j['color'] ?? ''}';
      } catch (_) {}
    }
    return ChatContact(
      id: row['id'] as String,
      nickname: row['nickname'] as String,
      chatCode: row['chat_code'] as String,
      avatarBase64: row['avatar_base64'] as String?,
      about: (row['about'] as String?) ?? '',
      addedAt: DateTime.parse(row['added_at'] as String),
      isGroup: isGroup,
      members: members,
      color: color,
    );
  }
}
