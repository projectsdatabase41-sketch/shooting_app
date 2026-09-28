import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'realtime_client.dart';
import 'remote_config.dart';

/// Живой канал ОДНОЙ открытой группы — аналог `LiveChatSession`, но без
/// P2P: WebRTC-mesh для текста не окупается (N участников — N×(N-1)/2
/// соединений ради килобит текста), поэтому только Broadcast всем, кто
/// сейчас держит группу открытой, плюс presence («кто в сети» без
/// опроса). Офлайн-участникам и истории это не мешает — обычная
/// доставка через базу (fan-out по участникам, `ChatSyncService._fanOut`)
/// идёт как раньше; этот канал только ускоряет тех, кто уже в сети.
class GroupLiveSession {
  GroupLiveSession({
    required this.auth,
    required this.repo,
    required this.groupId,
    this.onIncoming,
    this.onPresenceChanged,
    this.clientFactory,
  });

  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final String groupId;

  /// Пришло сообщение по живому каналу (уже сохранено в `repo`).
  final void Function()? onIncoming;

  /// Кто-то зашёл/вышел — `onlineCount`/`online()` изменились.
  final void Function()? onPresenceChanged;
  final RealtimeChannelClient Function(String topic)? clientFactory;

  static const _uuid = Uuid();
  static const _maxText = 8000;

  RealtimeChannelClient? _client;
  Timer? _retry;
  Timer? _tokenTimer;
  int _attempt = 0;
  bool _closed = false;

  /// Та же пауза, что у личных чатов — не долбим канал при отказе.
  static const List<Duration> _backoff = [Duration(seconds: 5), Duration(seconds: 20), Duration(minutes: 2)];

  String get topic => 'group:$groupId';

  /// Кто сейчас держит группу открытой (включая себя).
  bool online(String userId) => _client?.peers.contains(userId) == true;
  int get onlineCount => _client?.peers.length ?? 0;

  Future<void> open() async {
    if (_closed || !RemoteConfig.realtimeEnabled || !ChatSettings.isConfigured || !auth.isSignedIn) return;
    final token = await auth.ensureFreshToken();
    if (token == null || _closed) return;
    final c = clientFactory?.call(topic) ??
        RealtimeChannelClient(
          baseUrl: ChatSettings.url,
          anonKey: ChatSettings.anonKey,
          topic: topic,
          presenceKey: auth.userId,
        );
    c.onBroadcast = (event, p) {
      if (event == 'msg') _onBroadcast(p);
    };
    c.onPresenceChanged = onPresenceChanged;
    c.onClosed = _scheduleRetry;
    _client = c;
    if (await c.join(token)) {
      _attempt = 0;
      _tokenTimer?.cancel();
      _tokenTimer = Timer.periodic(const Duration(minutes: 45), (_) async {
        final t = await auth.ensureFreshToken();
        if (t != null) _client?.refreshToken(t);
      });
    }
  }

  void _scheduleRetry() {
    if (_closed || _attempt >= _backoff.length) return;
    _retry?.cancel();
    _retry = Timer(_backoff[_attempt++], () {
      _client = null;
      open();
    });
  }

  /// Рассылает текст присутствующим сейчас участникам — лучшая попытка,
  /// не гарантия доставки (для этого есть обычная отправка через базу,
  /// которую вызывающий код всё равно делает). Ничего не блокирует.
  void broadcastText(ChatMessage m) {
    _client?.sendBroadcast('msg', {
      'client_message_id': m.clientMessageId,
      'sender_id': auth.userId,
      'text': m.text,
      if (m.replyToClientMessageId != null) 'reply_to_client_message_id': m.replyToClientMessageId,
      if (m.replyToPreview != null) 'reply_to_preview': m.replyToPreview,
      'created_at': m.createdAt.toUtc().toIso8601String(),
    });
  }

  void _onBroadcast(Map<String, dynamic> p) {
    final clientId = p['client_message_id'];
    final senderId = p['sender_id'];
    if (clientId is! String || clientId.isEmpty || senderId is! String || senderId.isEmpty) return;
    if (senderId == auth.userId) return; // своё эхо не ждём (self:false), но не доверяем чужому payload
    final text = p['text'];
    if (text is! String || text.isEmpty || text.length > _maxText) return;
    if (repo.existsByClientId(clientId)) return; // уже есть — тем же путём или подъехало из базы
    repo.addMessage(ChatMessage(
      id: _uuid.v4(),
      clientMessageId: clientId,
      contactId: groupId,
      direction: ChatMessageDirection.incoming,
      text: text,
      status: ChatMessageStatus.delivered,
      senderId: senderId,
      replyToClientMessageId: p['reply_to_client_message_id'] as String?,
      replyToPreview: p['reply_to_preview'] as String?,
      createdAt: DateTime.tryParse('${p['created_at']}')?.toLocal() ?? DateTime.now(),
    ));
    onIncoming?.call();
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _tokenTimer?.cancel();
    _client?.onClosed = null;
    _client?.close();
    _client = null;
  }
}
