enum ChatMessageDirection { outgoing, incoming }

/// `sending` — уходит на сервер прямо сейчас; `sent` — принято сервером;
/// `delivered` — прочитано (в MVP сервер удаляет строку сразу после
/// того, как получатель её забрал, — упрощение по сравнению с полным
/// циклом "прочитано/уведомление отправителю", см. `ChatSyncService`);
/// `error` — не ушло, нужна ручная отправка повторно.
enum ChatMessageStatus { sending, sent, delivered, error }

/// Тип содержимого — как в Telegram/WhatsApp: обычный текст или
/// вложение одного из видов (фото/видео/голосовое/файл произвольного
/// формата). Подпись к вложению — то же поле `text`, необязательное.
///
/// `edit`/`delete` — служебные типы: НЕ отдельные сообщения в переписке,
/// а сигналы, которые `ChatSyncService.pollIncoming` применяет к уже
/// существующей локальной строке (меняет текст / удаляет) и сам не
/// сохраняет как новую запись — см. `ChatSyncService`.
///
/// `call` — "позвать" (кнопка в `ChatThreadScreen`): в отличие от
/// edit/delete это НАСТОЯЩЕЕ сообщение (остаётся в истории переписки),
/// просто без текста и вложения — весь смысл в push с усиленным звуком.
///
/// На проводе (не в этом enum — они никогда не сохраняются как
/// самостоятельная строка, только сигнал) есть ещё `call_ack`/
/// `call_cancel` — тот же принцип, что у edit/delete: правят поле
/// `callStatus` у уже существующей `call`-строки, см.
/// `ChatSyncService.acknowledgeCall`/`cancelCall`/`pollIncoming`.
enum ChatMessageType { text, image, video, audio, file, edit, delete, call }

class ChatMessage {
  final String id;

  /// Для дедупликации при повторной отправке — тот же принцип, что
  /// обсуждался в чате с Qwen (`client_message_id`).
  final String clientMessageId;
  final String contactId;
  final ChatMessageDirection direction;

  /// Текст сообщения либо подпись к вложению — `null`/пусто у чистого
  /// вложения без подписи.
  final String? text;
  final ChatMessageStatus status;
  final ChatMessageType type;

  /// Вложение целиком, как base64 (тот же приём, что у аватара,
  /// `AvatarUtils`) — сервер хранит файл только до получения (см.
  /// `sql/chat-schema.sql`, бакет `chat-media`), локально он остаётся
  /// навсегда как обычная история переписки.
  final String? attachmentBase64;
  final String? attachmentName;
  final String? attachmentMime;
  final int? attachmentSize;

  /// Большое вложение (свыше `ChatMediaUtils.maxAttachmentBytes`) — идёт
  /// не через `attachmentBase64`, а через отдельный Google Drive (см.
  /// `ChatDriveService`). `driveFileId` — id файла на Диске, пока он там
  /// ещё лежит (или до подтверждённого скачивания получателем).
  /// `attachmentLocalPath` — путь к уже скачанному файлу НА УСТРОЙСТВЕ:
  /// 5ГБ в SQLite строкой не кладут, поэтому в отличие от малых вложений
  /// байты тут не хранятся, только путь на диске.
  final String? driveFileId;
  final String? attachmentLocalPath;

  /// Правили ли текст после отправки (см. `edited` в локальной схеме).
  final bool edited;

  /// Ответ на другое сообщение этой же переписки — `replyToPreview`
  /// показывается всегда (короткая цитата), `replyToClientMessageId`
  /// нужен только для потенциального перехода к оригиналу.
  final String? replyToClientMessageId;
  final String? replyToPreview;

  /// Только для входящих — открыл ли получатель ветку с этим сообщением
  /// (см. комментарий у колонки `seen` в схеме).
  final bool seen;

  /// Разрешил ли ОТПРАВИТЕЛЬ скачивание вложения — его собственный выбор
  /// на момент отправки (см. `ChatPreferences.photoDownloadMode`), не
  /// имеет отношения к настройкам получателя. У своих сообщений
  /// (`direction == outgoing`) экраны игнорируют это поле — свой файл
  /// можно сохранить себе всегда.
  final bool downloadAllowed;

  /// Только для `type == call` — `null` (никак не отреагировали),
  /// `'acknowledged'` (тренер нажал "Иду") или `'cancelled'` (сам
  /// спортсмен отменил вызов, помощь больше не нужна). См. класс-докстринг.
  final String? callStatus;
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.clientMessageId,
    required this.contactId,
    required this.direction,
    this.text,
    required this.status,
    this.type = ChatMessageType.text,
    this.attachmentBase64,
    this.attachmentName,
    this.attachmentMime,
    this.attachmentSize,
    this.driveFileId,
    this.attachmentLocalPath,
    this.edited = false,
    this.replyToClientMessageId,
    this.replyToPreview,
    this.seen = false,
    this.downloadAllowed = true,
    this.callStatus,
    required this.createdAt,
  });

  ChatMessage copyWith({
    ChatMessageStatus? status,
    bool? seen,
    String? driveFileId,
    String? attachmentLocalPath,
  }) =>
      ChatMessage(
        id: id,
        clientMessageId: clientMessageId,
        contactId: contactId,
        direction: direction,
        text: text,
        status: status ?? this.status,
        type: type,
        attachmentBase64: attachmentBase64,
        attachmentName: attachmentName,
        attachmentMime: attachmentMime,
        attachmentSize: attachmentSize,
        driveFileId: driveFileId ?? this.driveFileId,
        attachmentLocalPath: attachmentLocalPath ?? this.attachmentLocalPath,
        edited: edited,
        replyToClientMessageId: replyToClientMessageId,
        replyToPreview: replyToPreview,
        seen: seen ?? this.seen,
        downloadAllowed: downloadAllowed,
        callStatus: callStatus,
        createdAt: createdAt,
      );

  factory ChatMessage.fromRow(Map<String, dynamic> row) => ChatMessage(
        id: row['id'] as String,
        clientMessageId: row['client_message_id'] as String,
        contactId: row['contact_id'] as String,
        direction: ChatMessageDirection.values.firstWhere((d) => d.name == row['direction']),
        text: row['text'] as String?,
        status: ChatMessageStatus.values.firstWhere((s) => s.name == row['status']),
        type: ChatMessageType.values.firstWhere(
          (t) => t.name == row['msg_type'],
          orElse: () => ChatMessageType.text,
        ),
        attachmentBase64: row['attachment_base64'] as String?,
        attachmentName: row['attachment_name'] as String?,
        attachmentMime: row['attachment_mime'] as String?,
        attachmentSize: (row['attachment_size'] as num?)?.toInt(),
        driveFileId: row['drive_file_id'] as String?,
        attachmentLocalPath: row['attachment_local_path'] as String?,
        edited: row['edited'] == 1 || row['edited'] == true,
        replyToClientMessageId: row['reply_to_client_message_id'] as String?,
        replyToPreview: row['reply_to_preview'] as String?,
        seen: row['seen'] == 1 || row['seen'] == true,
        downloadAllowed: row['download_allowed'] == null || row['download_allowed'] == 1 || row['download_allowed'] == true,
        callStatus: row['call_status'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
