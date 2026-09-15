import 'dart:convert';

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

  /// Ответ на сообщение — только id + короткая цитата (см.
  /// `ChatGlobalService.previewOf`), как в личном чате: полноценную связь
  /// незачем тянуть, цитата уже даёт контекст, а исходное сообщение может
  /// быть обрезано лимитом в 500 штук.
  final String? replyToId;
  final String? replyToPreview;

  /// Заполняются отдельным запросом (`resolve_profiles`) — сама лента
  /// отдаёт только `sender_id`, никнейм/аватар не хранятся построчно.
  final String? senderNickname;
  final String? senderAvatarBase64;

  /// Разрешил ли отправитель скачивание — см. `ChatMessage.downloadAllowed`
  /// (личный чат), тот же принцип: решение отправителя на момент отправки.
  final bool downloadAllowed;

  /// График (кнопка "AI" — решение пользователя: тот же ```chart JSON,
  /// что и в чате с ассистентом, см. `AiService.splitChart`/`AiChartView`,
  /// "универсальный язык" вместо своего формата для чата).
  final Map<String, dynamic>? chart;

  const ChatGlobalMessage({
    required this.id,
    required this.senderId,
    this.text,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentName,
    this.attachmentMime,
    this.attachmentSize,
    this.replyToId,
    this.replyToPreview,
    this.senderNickname,
    this.senderAvatarBase64,
    this.downloadAllowed = true,
    this.chart,
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
        replyToId: replyToId,
        replyToPreview: replyToPreview,
        senderNickname: nickname ?? senderNickname,
        senderAvatarBase64: avatarBase64 ?? senderAvatarBase64,
        downloadAllowed: downloadAllowed,
        chart: chart,
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
        replyToId: row['reply_to_id'] as String?,
        replyToPreview: row['reply_to_preview'] as String?,
        downloadAllowed: row['download_allowed'] == null || row['download_allowed'] == 1 || row['download_allowed'] == true,
        chart: _decodeChart(row['chart_json'] as String?),
      );

  static Map<String, dynamic>? _decodeChart(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
