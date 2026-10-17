import 'dart:convert';

import '../models/chat_message.dart';
import 'chat_messages_repository.dart';

/// Восстановление переписки у собеседника: после переустановки приложения
/// история лежит только у собеседников. Собеседник (с вашего согласия на его
/// стороне) пакует свою копию переписки, она приезжает по прямому каналу
/// (P2P / Realtime) файлом и вливается в вашу: уже имеющиеся сообщения
/// (по `clientMessageId`) не дублируются, направление «зеркалится».
class ChatHistoryTransfer {
  /// Вложение крупнее — не кладём в пакет (остаётся подпись и пометка).
  static const int maxAttachmentBytes = 2 * 1024 * 1024;

  /// Общий бюджет пакета.
  static const int maxPackageBytes = 40 * 1024 * 1024;

  static const _skipTypes = {ChatMessageType.edit, ChatMessageType.delete, ChatMessageType.call};

  /// Пакет для собеседника: мои исходящие станут его входящими и наоборот.
  static String encode(List<ChatMessage> messages) {
    var budget = maxPackageBytes;
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (_skipTypes.contains(m.type)) continue;
      var b64 = m.attachmentBase64;
      if (b64 != null && (b64.length > maxAttachmentBytes * 4 ~/ 3 || b64.length > budget)) b64 = null;
      if (b64 != null) budget -= b64.length;
      out.add({
        'c': m.clientMessageId,
        'd': m.direction == ChatMessageDirection.outgoing ? 'in' : 'out', // с точки зрения получателя пакета
        't': m.type.name,
        if (m.text != null) 'x': m.text,
        'at': m.createdAt.toUtc().toIso8601String(),
        if (b64 != null) 'b': b64,
        if (m.attachmentName != null) 'n': m.attachmentName,
        if (m.attachmentMime != null) 'm': m.attachmentMime,
        if (m.attachmentSize != null) 's': m.attachmentSize,
        if (m.replyToClientMessageId != null) 'rp': m.replyToClientMessageId,
        if (m.replyToPreview != null) 'rv': m.replyToPreview,
        if (m.edited) 'e': 1,
      });
    }
    return jsonEncode({'v': 1, 'messages': out});
  }

  /// Вливает пакет в переписку [contactId]; возвращает, сколько добавлено.
  static int import(ChatMessagesRepository repo, String contactId, String json, String Function() newId) {
    final root = jsonDecode(json);
    if (root is! Map || root['messages'] is! List) return 0;
    var added = 0;
    for (final raw in root['messages'] as List) {
      if (raw is! Map) continue;
      final cid = '${raw['c']}';
      if (cid.isEmpty || repo.existsByClientId(cid)) continue;
      final type = ChatMessageType.values.where((t) => t.name == raw['t']).firstOrNull ?? ChatMessageType.text;
      if (_skipTypes.contains(type)) continue;
      final incoming = raw['d'] == 'in';
      repo.addMessage(ChatMessage(
        id: newId(),
        clientMessageId: cid,
        contactId: contactId,
        direction: incoming ? ChatMessageDirection.incoming : ChatMessageDirection.outgoing,
        text: raw['x'] as String?,
        status: ChatMessageStatus.delivered,
        type: type,
        attachmentBase64: raw['b'] as String?,
        attachmentName: raw['n'] as String?,
        attachmentMime: raw['m'] as String?,
        attachmentSize: (raw['s'] as num?)?.toInt(),
        replyToClientMessageId: raw['rp'] as String?,
        replyToPreview: raw['rv'] as String?,
        seen: true, // старая история — не «новые непрочитанные»
        createdAt: DateTime.tryParse('${raw['at']}') ?? DateTime.now(),
      ));
      added++;
    }
    return added;
  }
}
