import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';

/// Сетевой обмен публичного чата — общий проект как ВРЕМЕННЫЙ транзит:
/// сообщение попадает на сервер при отправке и стирается оттуда, как
/// только получатель его забрал (упрощение по сравнению с полным циклом
/// "доставлено → прочитано → подтверждение отправителю" из обсуждения с
/// Qwen — для MVP этого достаточно, полный цикл можно добавить позже).
/// История остаётся только в локальных базах отправителя и получателя.
class ChatSyncService {
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final http.Client Function() clientFactory;

  ChatSyncService(this.auth, this.repo, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  static const _uuid = Uuid();
  static const Duration _timeout = Duration(seconds: 20);

  /// Отправляет сообщение: сохраняет локально сразу (видно в переписке
  /// немедленно), затем пытается уйти на сервер. Неудача — статус
  /// `error`, повторная отправка только вручную (решение пользователя:
  /// "отправитель сам перезапустит процесс"), без автоматических попыток.
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

  /// Повторная отправка уже существующего (в статусе `error`) сообщения.
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
  /// редкий опрос вместо push, тот убран в MVP). Как только строка
  /// прочитана этим запросом, она сразу удаляется с сервера — дальше
  /// живёт только в локальной истории получателя.
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
      final ids = <String>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final clientId = '${row['client_message_id']}';
        ids.add('${row['id']}');
        if (repo.existsByClientId(clientId)) continue; // уже приняли раньше
        repo.addMessage(ChatMessage(
          id: _uuid.v4(),
          clientMessageId: clientId,
          contactId: '${row['sender_id']}',
          direction: ChatMessageDirection.incoming,
          text: '${row['text']}',
          status: ChatMessageStatus.delivered,
          createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
        ));
        added++;
      }
      if (ids.isNotEmpty) await _deleteFromServer(ids, token, client);
      return added;
    } catch (_) {
      return 0;
    } finally {
      client.close();
    }
  }

  Future<void> _deleteFromServer(List<String> ids, String token, http.Client client) async {
    final filter = ids.map((id) => '"$id"').join(',');
    await client
        .delete(
          Uri.parse('${ChatSettings.url}/rest/v1/chat_messages?id=in.($filter)'),
          headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
        )
        .timeout(_timeout);
  }
}
