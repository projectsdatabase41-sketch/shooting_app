import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'realtime_client.dart';
import 'remote_config.dart';

/// Живой канал ОДНОГО открытого диалога (решение пользователя: личные чаты —
/// через WebSocket, база — для холодных сообщений и офлайна).
///
/// Схема: диалог открыт → входим в приватный канал `dm:<idA>:<idB>` и
/// объявляем присутствие. Пока собеседник тоже в канале, текстовое
/// сообщение уходит ему напрямую (Broadcast) и подтверждается ответом
/// `ack` за [ackTimeout]; нет подтверждения — вызывающий код шлёт через
/// базу как раньше. Получатель дедуплицирует по `client_message_id`, так
/// что «опоздавший» ack не создаёт двойников.
///
/// Всё выключено, пока в удалённом конфиге `realtime.enabled = false` —
/// тогда [open] ничего не делает, [trySend] сразу `false`.
class LiveChatSession {
  LiveChatSession({
    required this.auth,
    required this.repo,
    required this.contactId,
    this.onIncoming,
    this.ackTimeout = const Duration(seconds: 3),
    this.clientFactory,
  });

  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final String contactId;

  /// Пришло сообщение по живому каналу (уже сохранено в `repo`).
  final void Function()? onIncoming;
  final Duration ackTimeout;
  final RealtimeChannelClient Function(String topic)? clientFactory;

  static const _uuid = Uuid();
  static const _maxText = 8000;

  RealtimeChannelClient? _client;
  final Map<String, Completer<bool>> _acks = {};
  Timer? _retry;
  Timer? _tokenTimer;
  int _attempt = 0;
  bool _closed = false;

  /// Пауза после неудачного входа (лимит соединений, отказ RLS): не
  /// долбим канал, пока экран открыт, — просто остаёмся на базе.
  static const List<Duration> _backoff = [Duration(seconds: 5), Duration(seconds: 20), Duration(minutes: 2)];

  bool get peerOnline => _client?.isJoined == true && _client!.peers.contains(contactId);

  String get topic {
    final ids = [auth.userId, contactId]..sort();
    return 'dm:${ids[0]}:${ids[1]}';
  }

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
    c.onBroadcast = _onBroadcast;
    c.onClosed = () {
      _failPending();
      _scheduleRetry();
    };
    _client = c;
    if (await c.join(token)) {
      _attempt = 0;
      // Токен живёт около часа — обновляем в уже открытом канале.
      _tokenTimer?.cancel();
      _tokenTimer = Timer.periodic(const Duration(minutes: 45), (_) async {
        final t = await auth.ensureFreshToken();
        if (t != null) _client?.refreshToken(t);
      });
    }
  }

  void _scheduleRetry() {
    if (_closed || _attempt >= _backoff.length) return; // дальше — только база
    _retry?.cancel();
    _retry = Timer(_backoff[_attempt++], () {
      _client = null;
      open();
    });
  }

  void _failPending() {
    for (final c in _acks.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _acks.clear();
  }

  /// Пробует доставить сообщение напрямую. `true` — собеседник подтвердил;
  /// иначе вызывающий код обязан отправить через базу. Только обычный
  /// текст: вложения, правки и «позвать» идут как раньше.
  Future<bool> trySend(ChatMessage m) async {
    if (m.type != ChatMessageType.text || m.text == null || m.text!.length > _maxText) return false;
    final c = _client;
    if (c == null || !peerOnline) return false;
    final ack = Completer<bool>();
    _acks[m.clientMessageId] = ack;
    final sent = c.sendBroadcast('msg', {
      'client_message_id': m.clientMessageId,
      'text': m.text,
      if (m.replyToClientMessageId != null) 'reply_to_client_message_id': m.replyToClientMessageId,
      if (m.replyToPreview != null) 'reply_to_preview': m.replyToPreview,
      'created_at': m.createdAt.toUtc().toIso8601String(),
    });
    if (!sent) {
      _acks.remove(m.clientMessageId);
      return false;
    }
    final ok = await ack.future.timeout(ackTimeout, onTimeout: () => false);
    _acks.remove(m.clientMessageId);
    if (ok) repo.updateStatus(m.id, ChatMessageStatus.delivered);
    return ok;
  }

  void _onBroadcast(String event, Map<String, dynamic> p) {
    final clientId = p['client_message_id'];
    if (clientId is! String || clientId.isEmpty) return;
    if (event == 'ack') {
      _acks[clientId]?.complete(true);
      return;
    }
    if (event != 'msg') return;
    final text = p['text'];
    if (text is! String || text.isEmpty || text.length > _maxText) return;
    // Уже получено (тем же путём или через базу) — только повторяем ack.
    if (!repo.existsByClientId(clientId)) {
      repo.addMessage(ChatMessage(
        id: _uuid.v4(),
        clientMessageId: clientId,
        contactId: contactId,
        direction: ChatMessageDirection.incoming,
        text: text,
        status: ChatMessageStatus.delivered,
        replyToClientMessageId: p['reply_to_client_message_id'] as String?,
        replyToPreview: p['reply_to_preview'] as String?,
        createdAt: DateTime.tryParse('${p['created_at']}')?.toLocal() ?? DateTime.now(),
      ));
      onIncoming?.call();
    }
    _client?.sendBroadcast('ack', {'client_message_id': clientId});
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _tokenTimer?.cancel();
    _client?.onClosed = null;
    _client?.close();
    _client = null;
    _failPending();
  }
}
