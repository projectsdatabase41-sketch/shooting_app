import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import 'ai_service.dart';
import 'chat_auth_service.dart';
import 'chat_drive_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'live_chat_session.dart';

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

  /// Только для того, чтобы подтянуть ник/аватар отправителя, который
  /// ещё не в контактах (см. комментарий в `pollIncoming`) — та же
  /// RPC, что и в общем чате, отдельного клиента не заводим.

  /// Большие вложения (свыше `ChatMediaUtils.maxAttachmentBytes`) — идут
  /// не через `chat-media` в Storage, а через отдельный Google Drive
  /// (см. `ChatDriveService`).
  late final ChatDriveService drive = ChatDriveService(auth, clientFactory: clientFactory);

  /// Живой канал открытого диалога (см. `LiveChatSession`) — если задан и
  /// собеседник в нём, текст уходит напрямую, иначе как обычно через базу.
  LiveChatSession? live;

  /// Строка(и) для транзитной таблицы: личному собеседнику — одна, группе —
  /// по строке на каждого участника, кроме себя (группа живёт в
  /// `chat_contacts` как kind = 'group', см. `ChatContact`).
  Object _fanOut(String contactId, Map<String, dynamic> row) {
    final contact = repo.contactById(contactId);
    if (contact == null || !contact.isGroup) return {...row, 'recipient_id': contactId};
    return [
      for (final m in contact.members)
        if (m.id != auth.userId) {...row, 'recipient_id': m.id, 'group_id': contactId},
    ];
  }

  static const _uuid = Uuid();
  static const Duration _timeout = Duration(seconds: 60);
  static const _attachmentTypes = {
    ChatMessageType.image,
    ChatMessageType.video,
    ChatMessageType.audio,
    ChatMessageType.file,
  };

  /// "Позвать" — настоящее сообщение (остаётся в истории), но без
  /// текста и вложения: весь смысл в push с усиленным звуком/вибрацией
  /// (см. `chat_notify_push`/Edge Function), а не в содержимом.
  Future<ChatMessage> sendCall(String contactId) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      clientMessageId: _uuid.v4(),
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      status: ChatMessageStatus.sending,
      type: ChatMessageType.call,
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    auth.ensureFriendRequest(contactId);
    await retry(message);
    return message;
  }

  /// Отправляет текстовое сообщение: сохраняет локально сразу (видно в
  /// переписке немедленно), затем пытается уйти на сервер. Неудача —
  /// статус `error`, повторная отправка только вручную (решение
  /// пользователя: "отправитель сам перезапустит процесс"), без
  /// автоматических попыток.
  ///
  /// [replyTo] — сообщение, на которое отвечают (свайп по пузырю в
  /// интерфейсе) — цитата уходит собеседнику вместе с сообщением.
  Future<ChatMessage> send(String contactId, String text, {ChatMessage? replyTo}) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      clientMessageId: _uuid.v4(),
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      text: text,
      status: ChatMessageStatus.sending,
      replyToClientMessageId: replyTo?.clientMessageId,
      replyToPreview: replyTo == null ? null : previewOf(replyTo),
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    auth.ensureFriendRequest(contactId);
    await retry(message);
    return message;
  }

  /// Короткая цитата для превью "ответ на сообщение" — используется и
  /// при отправке (что уйдёт собеседнику), и в UI (полоска над полем
  /// ввода, пока идёт набор ответа).
  static String previewOf(ChatMessage m) {
    if (m.text != null && m.text!.isNotEmpty) {
      final (caption, chart) = AiService.splitChart(m.text!);
      if (caption.isEmpty && chart != null) return '📊 ${chart['title'] ?? 'График'}';
      return caption.length > 80 ? '${caption.substring(0, 80)}…' : caption;
    }
    return switch (m.type) {
      ChatMessageType.image => '📷 Фото',
      ChatMessageType.video => '🎥 Видео',
      ChatMessageType.audio => '🎤 Голосовое',
      ChatMessageType.file => '📎 ${m.attachmentName ?? 'Файл'}',
      _ => 'Сообщение',
    };
  }

  /// Правит уже отправленное сообщение задним числом — обновляет
  /// локальную копию сразу и рассылает собеседнику edit-сигнал (см.
  /// `msg_type = 'edit'` в `sql/chat-schema.sql`), который применяется
  /// к уже полученной у него строке, а не создаёт новую.
  Future<void> editMessage(ChatMessage original, String newText) async {
    repo.updateText(original.id, newText);
    if (!ChatSettings.isConfigured) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(_fanOut(original.contactId, {
              'client_message_id': _uuid.v4(),
              'sender_id': auth.userId,
              'text': newText,
              'msg_type': 'edit',
              'edit_of_client_message_id': original.clientMessageId,
            })),
          )
          .timeout(_timeout);
    } catch (_) {
      // Правка — необязательное усиление: если сигнал не дошёл, у
      // собеседника просто останется старый текст, ничего не ломается.
    } finally {
      client.close();
    }
  }

  /// Удаляет сообщение. [alsoRemote] — только для СВОИХ (outgoing)
  /// сообщений: шлёт собеседнику delete-сигнал, чтобы оно исчезло и у
  /// него. Чужое входящее можно удалить только у себя.
  Future<void> deleteMessage(ChatMessage message, {required bool alsoRemote}) async {
    repo.deleteMessage(message.id);
    if (!alsoRemote || !ChatSettings.isConfigured) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(_fanOut(message.contactId, {
              'client_message_id': _uuid.v4(),
              'sender_id': auth.userId,
              'msg_type': 'delete',
              'delete_of_client_message_id': message.clientMessageId,
            })),
          )
          .timeout(_timeout);
    } catch (_) {
      // Как и с правкой — необязательное усиление, локальное удаление
      // уже случилось независимо от результата.
    } finally {
      client.close();
    }
  }

  /// Тренер жмёт "Иду" на входящем вызове — обновляет свою локальную
  /// копию сразу и шлёт спортсмену `call_ack`-сигнал (тот же принцип,
  /// что у edit/delete): у спортсмена статус вызова переключится на
  /// "тренер идёт", без этого он бы не узнал, заметили ли его вообще.
  Future<void> acknowledgeCall(ChatMessage original) async {
    repo.updateCallStatus(original.id, 'acknowledged');
    if (!ChatSettings.isConfigured) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(_fanOut(original.contactId, {
              'client_message_id': _uuid.v4(),
              'sender_id': auth.userId,
              'msg_type': 'call_ack',
              'ack_of_client_message_id': original.clientMessageId,
            })),
          )
          .timeout(_timeout);
    } catch (_) {
      // Необязательное усиление — своя копия уже обновлена локально.
    } finally {
      client.close();
    }
  }

  /// Спортсмен передумал/справился сам — отменяет СВОЙ уже отправленный
  /// вызов. Обновляет локальную копию сразу и шлёт тренеру `call_cancel`-
  /// сигнал, чтобы у него вызов выглядел как "пропущенный, но уже не
  /// актуальный", а не висел вечно немым ожиданием ответа.
  Future<void> cancelCall(ChatMessage original) async {
    repo.updateCallStatus(original.id, 'cancelled');
    if (!ChatSettings.isConfigured) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(_fanOut(original.contactId, {
              'client_message_id': _uuid.v4(),
              'sender_id': auth.userId,
              'msg_type': 'call_cancel',
              'cancel_of_client_message_id': original.clientMessageId,
            })),
          )
          .timeout(_timeout);
    } catch (_) {
      // Необязательное усиление — своя копия уже обновлена локально.
    } finally {
      client.close();
    }
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
    bool downloadAllowed = true,
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
      downloadAllowed: downloadAllowed,
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    auth.ensureFriendRequest(contactId);
    await retry(message);
    return message;
  }

  /// Отправляет БОЛЬШОЕ вложение (свыше `ChatMediaUtils.maxAttachmentBytes`)
  /// через Google Drive вместо Storage — [filePath] уже лежит на диске
  /// (выбран через `ChatMediaUtils.pickLargeFile`, байты в память не
  /// читаются). Дальше та же схема статусов sending/sent/error, что и у
  /// обычного вложения — `retry` умеет повторить именно эту загрузку.
  Future<ChatMessage> sendLargeAttachment({
    required String contactId,
    required String filePath,
    required String fileName,
    required String mime,
    required ChatMessageType type,
    required int fileSize,
    String? caption,
    bool downloadAllowed = true,
  }) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      clientMessageId: _uuid.v4(),
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      text: caption,
      status: ChatMessageStatus.sending,
      type: type,
      attachmentName: fileName,
      attachmentMime: mime,
      attachmentSize: fileSize,
      attachmentLocalPath: filePath,
      downloadAllowed: downloadAllowed,
      createdAt: DateTime.now(),
    );
    repo.addMessage(message);
    auth.ensureFriendRequest(contactId);
    await retry(message);
    return message;
  }

  /// Повторная отправка уже существующего (в статусе `error`)
  /// сообщения — текстового или с вложением, различает по `type`.
  ///
  /// Раньше любая ошибка здесь просто оседала статусом `error` на
  /// пузыре, а вызывающий код (`_send`/`_attach`/`_call` в
  /// `ChatThreadScreen`) ничего не получал обратно — их собственный
  /// catch с сообщением пользователю никогда не срабатывал. Теперь
  /// ошибка (с реальным текстом от сервера, не просто кодом) прокидывается
  /// выше — статус на пузыре выставляется всё равно, но пользователь ещё
  /// и видит, что и почему не отправилось.
  Future<void> retry(ChatMessage message) async {
    // Большое вложение (Google Drive) — путь на диске есть, а обычных
    // байт для Storage нет: своя ветка, см. `_retryLargeAttachment`.
    if (message.attachmentLocalPath != null && _attachmentTypes.contains(message.type)) {
      return _retryLargeAttachment(message);
    }
    final l = live;
    if (l != null && l.contactId == message.contactId && await l.trySend(message)) return;
    if (!ChatSettings.isConfigured) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      throw Exception('Чат не настроен');
    }
    final token = await auth.ensureFreshToken();
    if (token == null) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      throw Exception('Сначала войдите в чат');
    }
    final client = clientFactory();
    try {
      String? attachmentPath;
      if (_attachmentTypes.contains(message.type)) {
        final b64 = message.attachmentBase64;
        if (b64 == null) throw Exception('Файл повреждён');
        attachmentPath =
            '${auth.userId}/${message.clientMessageId}/${ChatMediaUtils.safePathSegment(message.attachmentName ?? 'file')}';
        final uploadRes = await client
            .post(
              Uri.parse('${ChatSettings.url}/storage/v1/object/chat-media/$attachmentPath'),
              headers: {
                'apikey': ChatSettings.anonKey,
                'Authorization': 'Bearer $token',
                'Content-Type': message.attachmentMime ?? 'application/octet-stream',
                // Без x-upsert: перезапись требует ещё и права ЧИТАТЬ файл, а
                // оно появляется только после записи сообщения — Supabase
                // отвечал «violates row-level security policy».
              },
              body: base64Decode(b64),
            )
            .timeout(_timeout);
        // «Уже существует» — это повторная отправка после сбоя: файл уже на
        // месте, дальше просто записываем сообщение.
        final duplicate = uploadRes.statusCode == 409 || uploadRes.body.contains('Duplicate') || uploadRes.body.contains('already exists');
        if (uploadRes.statusCode >= 300 && !duplicate) {
          throw Exception('Не удалось загрузить файл (${uploadRes.statusCode}): ${uploadRes.body}');
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
            body: jsonEncode(_fanOut(message.contactId, {
              'client_message_id': message.clientMessageId,
              'sender_id': auth.userId,
              'text': message.text,
              'msg_type': message.type.name,
              if (attachmentPath != null) 'attachment_path': attachmentPath,
              if (message.attachmentName != null) 'attachment_name': message.attachmentName,
              if (message.attachmentMime != null) 'attachment_mime': message.attachmentMime,
              if (message.attachmentSize != null) 'attachment_size': message.attachmentSize,
              if (message.replyToClientMessageId != null) 'reply_to_client_message_id': message.replyToClientMessageId,
              if (message.replyToPreview != null) 'reply_to_preview': message.replyToPreview,
              'download_allowed': message.downloadAllowed,
            })),
          )
          .timeout(_timeout);
      if (res.statusCode >= 300) {
        throw Exception('Сервер ответил ${res.statusCode}: ${res.body}');
      }
      repo.updateStatus(message.id, ChatMessageStatus.sent);
    } catch (e) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Загружает большое вложение на Drive (если ещё не загружено —
  /// `driveFileId == null`) и шлёт метаданные в `chat_messages` тем же
  /// способом, что и обычное вложение, только с `drive_file_id` вместо
  /// `attachment_path`. Повторный вызов (после ошибки) пропускает уже
  /// готовую загрузку и просто досылает строку.
  Future<void> _retryLargeAttachment(ChatMessage message) async {
    if (!ChatSettings.isConfigured) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      throw Exception('Чат не настроен');
    }
    final token = await auth.ensureFreshToken();
    if (token == null) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      throw Exception('Сначала войдите в чат');
    }
    try {
      var driveFileId = message.driveFileId;
      if (driveFileId == null) {
        driveFileId = await drive.upload(
          filePath: message.attachmentLocalPath!,
          fileName: message.attachmentName ?? 'file',
          mime: message.attachmentMime ?? 'application/octet-stream',
        );
        repo.updateDriveFileId(message.id, driveFileId);
      }

      final client = clientFactory();
      try {
        final res = await client
            .post(
              Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
              headers: {
                'apikey': ChatSettings.anonKey,
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal,resolution=ignore-duplicates',
              },
              body: jsonEncode(_fanOut(message.contactId, {
                'client_message_id': message.clientMessageId,
                'sender_id': auth.userId,
                'text': message.text,
                'msg_type': message.type.name,
                'drive_file_id': driveFileId,
                if (message.attachmentName != null) 'attachment_name': message.attachmentName,
                if (message.attachmentMime != null) 'attachment_mime': message.attachmentMime,
                if (message.attachmentSize != null) 'attachment_size': message.attachmentSize,
                if (message.replyToClientMessageId != null) 'reply_to_client_message_id': message.replyToClientMessageId,
                if (message.replyToPreview != null) 'reply_to_preview': message.replyToPreview,
                'download_allowed': message.downloadAllowed,
              })),
            )
            .timeout(_timeout);
        if (res.statusCode >= 300) {
          throw Exception('Сервер ответил ${res.statusCode}: ${res.body}');
        }
        repo.updateStatus(message.id, ChatMessageStatus.sent);
      } finally {
        client.close();
      }
    } catch (e) {
      repo.updateStatus(message.id, ChatMessageStatus.error);
      rethrow;
    }
  }

  /// Скачивает большое вложение (кнопка "Скачать" на пузыре в чате) —
  /// потоково в [destPath], без буферизации в памяти. После успешного
  /// скачивания стирает файл с Диска (самоочистка, как и просил
  /// пользователь) — best-effort, неудача чистки не мешает пользователю
  /// увидеть уже скачанный файл.
  Future<void> downloadLargeAttachment(ChatMessage message, {required String destPath, void Function(int, int?)? onProgress}) async {
    final fileId = message.driveFileId;
    if (fileId == null) throw Exception('Нечего скачивать');
    await drive.download(fileId: fileId, destPath: destPath, onProgress: onProgress);
    repo.updateAttachmentLocalPath(message.id, destPath);
    unawaited(drive.deleteFile(fileId));
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
      // Добавление контакта — однонаправленное (кто добавил по коду/из
      // общего чата, у того он и есть). Без этого входящее от ещё не
      // добавленного отправителя сохранялось бы локально, но переписку
      // было бы негде увидеть — в списке контактов такого отправителя
      // просто нет. Поэтому первое сообщение от незнакомца заводит его
      // в контакты автоматически, как "запрос на переписку" в обычных
      // мессенджерах — если только пользователь не включил режим
      // "только по заявке" (см. ниже).
      final knownContacts = repo.listContacts().map((c) => c.id).toSet();
      // Не друзья ещё в этом опросе — их строки оставляем на сервере
      // нетронутыми (не скачиваем, не удаляем), пока заявку не примут;
      // без этого кэша каждое их сообщение слало бы отдельный запрос
      // статуса заявки на каждый цикл опроса.
      final notYetFriends = <String>{};
      final friendsOnly = auth.privacyMode == 'friends_only';
      var groupsSynced = false;
      for (final row in decoded) {
        if (row is! Map) continue;
        final senderId = '${row['sender_id']}';
        final rawType = '${row['msg_type']}';
        // Сообщение группы живёт в диалоге группы, а не в личке с автором.
        final groupId = row['group_id'] as String?;
        final threadId = groupId ?? senderId;

        if (groupId != null) {
          if (!knownContacts.contains(groupId) && !groupsSynced) {
            groupsSynced = true;
            await syncGroups();
            knownContacts.addAll(repo.listContacts().map((c) => c.id));
          }
          if (!knownContacts.contains(groupId)) continue; // группа ещё не видна — в следующий раз
        } else if (notYetFriends.contains(senderId)) {
          continue;
        } else if (!knownContacts.contains(senderId)) {
          if (friendsOnly && await auth.friendStatusWith(senderId) != 'accepted') {
            notYetFriends.add(senderId);
            continue;
          }
          final profile = (await auth.resolveProfiles([senderId]))[senderId];
          repo.addContact(ChatContact(
            id: senderId,
            nickname: profile?.nickname ?? '—',
            chatCode: '',
            avatarBase64: profile?.avatarBase64,
            about: profile?.about ?? '',
            addedAt: DateTime.now(),
          ));
          knownContacts.add(senderId);
        }

        // edit/delete — сигналы к уже полученной строке, не новые
        // сообщения: применяем и чистим транзитную строку, минуя
        // обычную дедупликацию по client_message_id (у сигнала он свой).
        if (rawType == 'edit') {
          final target = repo.byClientId(threadId, '${row['edit_of_client_message_id']}');
          if (target != null) repo.updateText(target.id, '${row['text'] ?? ''}');
          doneIds.add('${row['id']}');
          continue;
        }
        if (rawType == 'delete') {
          final target = repo.byClientId(threadId, '${row['delete_of_client_message_id']}');
          if (target != null) repo.deleteMessage(target.id);
          doneIds.add('${row['id']}');
          continue;
        }
        if (rawType == 'read') {
          try {
            final ids = (jsonDecode('${row['text']}') as List).map((e) => '$e').toList();
            repo.markPeerRead(threadId, ids);
          } catch (_) {}
          doneIds.add('${row['id']}');
          continue;
        }
        if (rawType == 'call_ack') {
          final target = repo.byClientId(threadId, '${row['ack_of_client_message_id']}');
          if (target != null) repo.updateCallStatus(target.id, 'acknowledged');
          doneIds.add('${row['id']}');
          continue;
        }
        if (rawType == 'call_cancel') {
          final target = repo.byClientId(threadId, '${row['cancel_of_client_message_id']}');
          if (target != null) repo.updateCallStatus(target.id, 'cancelled');
          doneIds.add('${row['id']}');
          continue;
        }

        final clientId = '${row['client_message_id']}';
        if (repo.existsByClientId(clientId)) {
          doneIds.add('${row['id']}'); // уже приняли раньше, просто дочистим строку
          continue;
        }

        final type = ChatMessageType.values.firstWhere(
          (t) => t.name == rawType,
          orElse: () => ChatMessageType.text,
        );
        String? attachmentBase64;
        final path = row['attachment_path'] as String?;
        // drive_file_id — большое вложение: строка приезжает сразу, а
        // сам файл получатель скачивает позже вручную (кнопка
        // "Скачать" в чате, см. `downloadLargeAttachment`) — тянуть
        // гигабайты прямо тут, при обычном опросе, нельзя.
        final driveFileId = row['drive_file_id'] as String?;
        if (type != ChatMessageType.text && path != null) {
          final bytes = await _downloadAttachment(path, token, client);
          if (bytes == null) continue; // не скачалось — попробуем в следующий опрос, строку не трогаем
          attachmentBase64 = base64Encode(bytes);
          // ponytail: файл группы нужен всем участникам — не удаляем его после
          // первого получателя; чистка хранилища по сроку — когда начнёт копиться.
          if (groupId == null) await _deleteAttachment(path, token, client);
        }

        repo.addMessage(ChatMessage(
          id: _uuid.v4(),
          clientMessageId: clientId,
          contactId: threadId,
          senderId: groupId == null ? null : senderId,
          direction: ChatMessageDirection.incoming,
          text: row['text'] as String?,
          status: ChatMessageStatus.delivered,
          type: type,
          attachmentBase64: attachmentBase64,
          attachmentName: row['attachment_name'] as String?,
          attachmentMime: row['attachment_mime'] as String?,
          attachmentSize: (row['attachment_size'] as num?)?.toInt(),
          driveFileId: driveFileId,
          replyToClientMessageId: row['reply_to_client_message_id'] as String?,
          replyToPreview: row['reply_to_preview'] as String?,
          downloadAllowed: row['download_allowed'] == null || row['download_allowed'] == true,
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

  /// Сообщает собеседнику, что его сообщения прочитаны (личный чат; в
  /// группах отметки не шлём — это N сообщений на каждое прочтение).
  Future<void> reportRead(String contactId) async {
    final contact = repo.contactById(contactId);
    if (contact == null || contact.isGroup || !ChatSettings.isConfigured) return;
    final ids = repo.unreportedRead(contactId);
    if (ids.isEmpty) return;
    final token = await auth.ensureFreshToken();
    if (token == null) return;
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({
              'client_message_id': _uuid.v4(),
              'sender_id': auth.userId,
              'recipient_id': contactId,
              'msg_type': 'read',
              'text': jsonEncode(ids),
            }),
          )
          .timeout(_timeout);
      // Сервер без типа 'read' (SQL не обновлён) ответит 400 — попробуем позже.
      if (res.statusCode < 300) repo.markReadReported(contactId, ids);
    } catch (_) {
    } finally {
      client.close();
    }
  }

  /// Мои группы с сервера → строки `chat_contacts` (kind = 'group'). Группы,
  /// из которых меня убрали, остаются локально с историей, но писать туда
  /// уже нельзя (сервер отклонит).
  Future<void> syncGroups() async {
    final groups = await auth.myGroups();
    for (final g in groups) {
      final existing = repo.contactById(g.id);
      repo.addContact(ChatContact(
        id: g.id,
        nickname: g.nickname,
        chatCode: '',
        avatarBase64: g.avatarBase64,
        about: g.about,
        addedAt: existing?.addedAt ?? DateTime.now(),
        isGroup: true,
        members: g.members,
        color: g.color,
      ));
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
