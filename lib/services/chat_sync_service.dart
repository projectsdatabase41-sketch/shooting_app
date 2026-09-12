import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';

/// Сетевой обмен публичного чата — общий проект как ВРЕМЕННЫЙ транзит:
/// сообщение (и вложение, если есть) попадает на сервер при отправке и
/// стирается оттуда, как только получатель его забрал (упрощение по
/// сравнению с полным циклом "доставлено → прочитано → подтверждение
/// отправителю" из обсуждения с Qwen — для MVP этого достаточно, полный
/// цикл можно добавить позже). История остаётся только в локальных
/// базах отправителя и получателя — вложение целиком, как base64 (см.
/// `ChatMessage.attachmentBase64`).
class ChatSyncService {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final http.Client Function() clientFactory;

  ChatSyncService(this.auth, this.repo, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  static const _uuid = Uuid();
  static const Duration _timeout = Duration(seconds: 60);

  /// Отправляет текстовое сообщение: сохраняет локально сразу (видно в
  /// переписке немедленно), затем пытается уйти на сервер. Неудача —
  /// статус `error`, повторная отправка только вручную (решение
  /// пользователя: "отправитель сам перезапустит процесс"), без
  /// автоматических попыток.
  Future<ChatMessage> send(String contactId, String text) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      clientMessageId: _uuid.v4(),
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      text: text,
      status: ChatMessageStatus.sending,
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    await retry(message);
    return message;
  }

  /// Отправляет вложение (фото/файл — запись видео/голоса пока не
  /// реализована в интерфейсе, хотя схема и этот метод их уже
  /// поддерживают, `type` принимает любое значение). [bytes] — уже
  /// готовые к отправке байты: для фото сжатие делает вызывающий код
  /// через `ChatMediaUtils.compressImage` ДО вызова, здесь их не трогают.
  Future<ChatMessage> sendAttachment({
    required String contactId,
    required List<int> bytes,
    required String fileName,
    required String mime,
    required ChatMessageType type,
    String? caption,
  }) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      clientMessageId: _uuid.v4(),
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      text: caption,
      status: ChatMessageStatus.sending,
      type: type,
      attachmentBase64: base64Encode(bytes),
      attachmentName: fileName,
      attachmentMime: mime,
      attachmentSize: bytes.length,
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    await retry(message);
    return message;
  }

  /// Повторная отправка уже существующего (в статусе `error`)
  /// сообщения — текстового или с вложением, различает по `type`.
  Future<void> retry(ChatMessage message) async {
    if (!ChatSettings.isConfigured) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      return;
    }
    final token = await auth.ensureFreshToken();
    if (token == null) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      return;
    }
    final client = clientFactory();
    try {
      String? attachmentPath;
      if (message.type != ChatMessageType.text) {
        final b64 = message.attachmentBase64;
        if (b64 == null) {
          repo.updateStatus(message.id, ChatMessageStatus.error);
          return;
        }
        attachmentPath = '${auth.userId}/${message.clientMessageId}/${message.attachmentName ?? 'file'}';
        final uploadRes = await client
            .post(
              Uri.parse('${ChatSettings.url}/storage/v1/object/chat-media/$attachmentPath'),
              headers: {
                'apikey': ChatSettings.anonKey,
                'Authorization': 'Bearer $token',
                'Content-Type': message.attachmentMime ?? 'application/octet-stream',
                // Повторная отправка перезаписывает тот же путь вместо
                // ошибки "уже существует".
                'x-upsert': 'true',
              },
              body: base64Decode(b64),
            )
            .timeout(_timeout);
        if (uploadRes.statusCode >= 300) {
          repo.updateStatus(message.id, ChatMessageStatus.error);
          return;
        }
      }

      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              // on_conflict — повторная отправка с тем же
              // client_message_id не создаёт дубль на сервере.
              'Prefer': 'return=minimal,resolution=ignore-duplicates',
            },
            body: jsonEncode({
              'client_message_id': message.clientMessageId,
              'sender_id': auth.userId,
              'recipient_id': message.contactId,
              'text': message.text,
              'msg_type': message.type.name,
              if (attachmentPath != null) 'attachment_path': attachmentPath,
              if (message.attachmentName != null) 'attachment_name': message.attachmentName,
              if (message.attachmentMime != null) 'attachment_mime': message.attachmentMime,
              if (message.attachmentSize != null) 'attachment_size': message.attachmentSize,
            }),
          )
          .timeout(_timeout);
      repo.updateStatus(message.id, res.statusCode < 300 ? ChatMessageStatus.sent : ChatMessageStatus.error);
    } catch (_) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
    } finally {
      client.close();
    }
  }

  /// Забирает новые входящие сообщения ОТ ВСЕХ контактов разом — вызывать
  /// периодически, пока открыто приложение (решение пользователя:
  /// редкий опрос вместо push, тот убран в MVP). Вложение (если есть)
  /// скачивается ЦЕЛИКОМ и кладётся в локальную базу как base64, ПОСЛЕ
  /// чего объект и строка удаляются с сервера — дальше живёт только в
  /// локальной истории получателя.
  Future<int> pollIncoming() async {
    if (!ChatSettings.isConfigured) return 0;
    final token = await auth.ensureFreshToken();
    if (token == null) return 0;
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('${ChatSettings.url}/rest/v1/chat_messages?recipient_id=eq.${auth.userId}&select=*'),
        headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(_timeout);
      if (res.statusCode >= 400) return 0;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return 0;

      var added = 0;
      final doneIds = <String>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final clientId = '${row['client_message_id']}';
        if (repo.existsByClientId(clientId)) {
          doneIds.add('${row['id']}'); // уже приняли раньше, просто дочистим строку
          continue;
        }

        final type = ChatMessageType.values.firstWhere(
          (t) => t.name == row['msg_type'],
          orElse: () => ChatMessageType.text,
        );
        String? attachmentBase64;
        final path = row['attachment_path'] as String?;
        if (type != ChatMessageType.text && path != null) {
          final bytes = await _downloadAttachment(path, token, client);
          if (bytes == null) continue; // не скачалось — попробуем в следующий опрос, строку не трогаем
          attachmentBase64 = base64Encode(bytes);
          await _deleteAttachment(path, token, client);
        }

        repo.addMessage(ChatMessage(
          id: _uuid.v4(),
          clientMessageId: clientId,
          contactId: '${row['sender_id']}',
          direction: ChatMessageDirection.incoming,
          text: row['text'] as String?,
          status: ChatMessageStatus.delivered,
          type: type,
          attachmentBase64: attachmentBase64,
          attachmentName: row['attachment_name'] as String?,
          attachmentMime: row['attachment_mime'] as String?,
          attachmentSize: (row['attachment_size'] as num?)?.toInt(),
          createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
        ));
        added++;
        doneIds.add('${row['id']}');
      }
      if (doneIds.isNotEmpty) await _deleteMessages(doneIds, token, client);
      return added;
    } catch (_) {
      return 0;
    } finally {
      client.close();
    }
  }

  Future<List<int>?> _downloadAttachment(String path, String token, http.Client client) async {
    try {
      final res = await client.get(
        Uri.parse('${ChatSettings.url}/storage/v1/object/chat-media/$path'),
        headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(_timeout);
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Объект в Storage надо стереть, пока строка `chat_messages` ещё
  /// существует — политика удаления (`chat_media_delete` в
  /// `sql/chat-schema.sql`) разрешает это только по ссылающейся строке.
  Future<void> _deleteAttachment(String path, String token, http.Client client) async {
    try {
      await client
          .delete(
            Uri.parse('${ChatSettings.url}/storage/v1/object/chat-media/$path'),
            headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
    } catch (_) {
      // Не страшно: осиротевший объект без строки никто больше не
      // скачает (политика на select/delete требует существующую
      // ссылающуюся строку), можно почистить вручную позже.
    }
  }

  Future<void> _deleteMessages(List<String> ids, String token, http.Client client) async {
    final filter = ids.map((id) => '"$id"').join(',');
    await client
        .delete(
          Uri.parse('${ChatSettings.url}/rest/v1/chat_messages?id=in.($filter)'),
          headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
        )
        .timeout(_timeout);
  }
}
