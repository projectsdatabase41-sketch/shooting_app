import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../logic/chat_media_utils.dart';
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
  static const _uuid = Uuid();

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

  Future<void> send(String text, {String? replyToId, String? replyToPreview}) async {
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
            body: jsonEncode({
              'sender_id': auth.userId,
              'text': text,
              if (replyToId != null) 'reply_to_id': replyToId,
              if (replyToPreview != null) 'reply_to_preview': replyToPreview,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode >= 300) throw Exception('Не удалось отправить (${res.statusCode})');
    } finally {
      client.close();
    }
  }

  /// Короткая цитата для превью "ответ на сообщение" — тот же приём, что
  /// `ChatSyncService.previewOf`, своя копия под другую модель сообщения.
  static String previewOf(ChatGlobalMessage m) {
    if (m.text != null && m.text!.isNotEmpty) {
      return m.text!.length > 80 ? '${m.text!.substring(0, 80)}…' : m.text!;
    }
    if (m.isImage) return '📷 Фото';
    if (m.hasAttachment) return '📎 ${m.attachmentName ?? 'Файл'}';
    return 'Сообщение';
  }

  /// Удаляет своё сообщение из общей ленты (меню долгого нажатия) —
  /// RLS (`chat_global_delete`) и так не даёт удалить чужое, но
  /// вызывающий код всё равно проверяет владельца сам, чтобы не
  /// показывать пункт "Удалить" там, где он всё равно не сработает.
  Future<void> delete(String id) async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception('Сначала войдите в чат');
    final client = clientFactory();
    try {
      final res = await client.delete(
        Uri.parse('${ChatSettings.url}/rest/v1/chat_global_messages?id=eq.$id'),
        headers: {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer $token'},
      ).timeout(_timeout);
      if (res.statusCode >= 300) throw Exception('Не удалось удалить (${res.statusCode})');
    } finally {
      client.close();
    }
  }

  /// Фото/файл в общую ленту — путь "global/<sender_id>/..." (см.
  /// sql/chat-schema.sql), в отличие от личного чата объект НЕ
  /// удаляется после просмотра: лента общая и постоянная.
  Future<void> sendAttachment({
    required List<int> bytes,
    required String fileName,
    required String mime,
    String? caption,
    bool downloadAllowed = true,
  }) async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception('Сначала войдите в чат');
    final path = 'global/${auth.userId}/${_uuid.v4()}/${ChatMediaUtils.safePathSegment(fileName)}';
    final client = clientFactory();
    try {
      final uploadRes = await client
          .post(
            Uri.parse('${ChatSettings.url}/storage/v1/object/chat-media/$path'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': mime,
            },
            body: bytes,
          )
          .timeout(_timeout);
      if (uploadRes.statusCode >= 300) throw Exception('Не удалось загрузить файл (${uploadRes.statusCode})');

      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/chat_global_messages'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({
              'sender_id': auth.userId,
              if (caption != null && caption.isNotEmpty) 'text': caption,
              'attachment_path': path,
              'attachment_name': fileName,
              'attachment_mime': mime,
              'attachment_size': bytes.length,
              'download_allowed': downloadAllowed,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode >= 300) throw Exception('Не удалось отправить (${res.statusCode})');
    } finally {
      client.close();
    }
  }

  /// Временная подписанная ссылка на вложение — бакет приватный, обычный
  /// `Image.network` без заголовков её не откроет. Кэшировать на
  /// стороне вызывающего (см. `_GlobalChatBody`) — на каждый показ
  /// перезапрашивать не нужно, ссылка живёт `expiresIn` секунд.
  Future<String?> signedUrl(String path, {int expiresIn = 3600}) async {
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/storage/v1/object/sign/chat-media/$path'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'expiresIn': expiresIn}),
          )
          .timeout(_timeout);
      if (res.statusCode >= 400) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final signedPath = decoded is Map ? decoded['signedURL'] as String? : null;
      if (signedPath == null) return null;
      return '${ChatSettings.url}/storage/v1$signedPath';
    } catch (_) {
      return null;
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
