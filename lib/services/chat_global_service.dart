import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_global_message.dart';
import 'chat_auth_service.dart';
import 'chat_settings.dart';

/// Общий (всемирный) чат — один поток на всех пользователей платформы,
/// в отличие от `ChatSyncService` (личная переписка двоих, транзит).
/// Сообщения хранятся на сервере, клиент просто читает последние N —
/// своей локальной копии здесь нет, лента всегда живая.
class ChatGlobalService {
  final ChatAuthService auth;
  final http.Client Function() clientFactory;

  ChatGlobalService(this.auth, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  static const Duration _timeout = Duration(seconds: 20);

  /// Последние [limit] сообщений, от старых к новым (готово для
  /// показа в ленте сверху вниз). Ники/аватары уже подставлены —
  /// одним дополнительным запросом на уникальных отправителей.
  Future<List<ChatGlobalMessage>> fetchRecent({int limit = 200}) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return const [];
    final client = clientFactory();
    try {
      final res = await client.get(
        Uri.parse('${ChatSettings.url}/rest/v1/chat_global_messages')
            .replace(queryParameters: {'select': '*', 'order': 'created_at.desc', 'limit': '$limit'}),
        headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(_timeout);
      if (res.statusCode >= 400) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      final messages = decoded.map((r) => ChatGlobalMessage.fromRow(r as Map<String, dynamic>)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final ids = messages.map((m) => m.senderId).toSet().toList();
      final profiles = await resolveProfiles(ids);
      return [
        for (final m in messages)
          m.withProfile(nickname: profiles[m.senderId]?.$1, avatarBase64: profiles[m.senderId]?.$2),
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  Future<void> send(String text) async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception('Сначала войдите в чат');
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_global_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({'sender_id': auth.userId, 'text': text}),
          )
          .timeout(_timeout);
      if (res.statusCode >= 300) throw Exception('Не удалось отправить (${res.statusCode})');
    } finally {
      client.close();
    }
  }

  /// Никнейм+аватар по списку id — та же `resolve_chat_code`-идея, но
  /// без кода контакта (в общей ленте свой код никому не открывают,
  /// добавляют друг друга напрямую по уже известному id — см.
  /// `_GlobalChatBody._addAsContact` в chat_home_screen.dart).
  Future<Map<String, (String, String?)>> resolveProfiles(List<String> ids) async {
    if (ids.isEmpty) return {};
    final token = await auth.ensureFreshToken();
    if (token == null) return {};
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/rpc/resolve_profiles'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'p_ids': ids}),
          )
          .timeout(_timeout);
      if (res.statusCode >= 400) return {};
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return {};
      return {
        for (final row in decoded.cast<Map<String, dynamic>>())
          '${row['user_id']}': ('${row['nickname']}', row['avatar_base64'] as String?),
      };
    } catch (_) {
      return {};
    } finally {
      client.close();
    }
  }
}
