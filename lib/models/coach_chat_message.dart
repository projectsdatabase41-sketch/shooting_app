/// Сообщение «Чата с тренером» (sql/coach-chat.sql). [authorRole] —
/// 'athlete' или 'coach'.
typedef CoachChatMessage = ({String id, String authorRole, String text, DateTime createdAt});

CoachChatMessage coachChatFromRow(Map<String, dynamic> r) => (
      id: '${r['id']}',
      authorRole: '${r['author_role']}',
      text: '${r['text'] ?? ''}',
      createdAt: DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now(),
    );
