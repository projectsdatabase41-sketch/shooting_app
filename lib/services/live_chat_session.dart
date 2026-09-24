import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'peer_link.dart';
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
    this.linkFactory,
  });

  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final String contactId;

  /// Пришло сообщение по живому каналу (уже сохранено в `repo`).
  final void Function()? onIncoming;
  final Duration ackTimeout;
  final RealtimeChannelClient Function(String topic)? clientFactory;

  /// Фабрика прямого соединения (WebRTC). Пока `null` или флаг `webrtc`
  /// выключен — только Broadcast.
  final PeerLink Function()? linkFactory;

  static const _uuid = Uuid();
  static const _maxText = 8000;

  RealtimeChannelClient? _client;
  final Map<String, Completer<bool>> _acks = {};
  Timer? _retry;
  Timer? _tokenTimer;
  int _attempt = 0;
  bool _closed = false;
  PeerLink? _link;
  int _rtcTries = 0;
  static const int _maxRtcTries = 2;

  /// Пауза после неудачного входа (лимит соединений, отказ RLS): не
  /// долбим канал, пока экран открыт, — просто остаёмся на базе.
  static const List<Duration> _backoff = [Duration(seconds: 5), Duration(seconds: 20), Duration(minutes: 2)];

  bool get peerOnline => _link?.isOpen == true || (_client?.isJoined == true && _client!.peers.contains(contactId));

  /// Идёт ли обмен напрямую (WebRTC), минуя сервер.
  bool get isDirect => _link?.isOpen == true;

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
    c.onBroadcast = (event, p) {
      if (event == 'rtc') {
        _onSignal(p);
      } else {
        _onBroadcast(event, p);
      }
    };
    c.onPresenceChanged = _maybeStartRtc;
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
    if (!peerOnline) return false;
    final ack = Completer<bool>();
    _acks[m.clientMessageId] = ack;
    final sent = _emit('msg', {
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
    _emit('ack', {'client_message_id': clientId});
  }

  /// Сначала прямой канал, иначе Broadcast через сервер.
  bool _emit(String event, Map<String, dynamic> payload) {
    final l = _link;
    if (l != null && l.isOpen && l.send(encodePeerFrame(event, payload))) return true;
    return _client?.sendBroadcast(event, payload) ?? false;
  }

  /// Соединение по WebRTC поднимает тот, у кого id меньше (иначе оба
  /// одновременно отправили бы offer). Второй создаёт линк, когда придёт
  /// первый сигнал.
  void _maybeStartRtc() {
    if (_closed || _link != null || linkFactory == null || !RemoteConfig.webrtcEnabled) return;
    if (_rtcTries >= _maxRtcTries || _client?.peers.contains(contactId) != true) return;
    if (auth.userId.compareTo(contactId) >= 0) return;
    _newLink().start(initiator: true);
  }

  PeerLink _newLink() {
    _rtcTries++;
    final l = linkFactory!();
    _link = l;
    l.onSignal = (s) => _client?.sendBroadcast('rtc', s);
    l.onMessage = (raw) {
      final f = decodePeerFrame(raw);
      if (f != null) _onBroadcast(f.$1, f.$2);
    };
    // onState зовётся только при открытии и закрытии канала.
    l.onState = () {
      if (_link == l && !l.isOpen) {
        _link = null;
        _maybeStartRtc(); // не более _maxRtcTries попыток за диалог
      }
    };
    return l;
  }

  void _onSignal(Map<String, dynamic> s) {
    if (_closed || linkFactory == null || !RemoteConfig.webrtcEnabled) return;
    var l = _link;
    if (l == null) {
      if (s['kind'] != 'offer' || _rtcTries >= _maxRtcTries) return; // начинает только тот, у кого id меньше
      l = _newLink();
      l.start(initiator: false);
    }
    l.handleSignal(s);
  }

  void close() {
    _closed = true;
    _link?.close();
    _link = null;
    _retry?.cancel();
    _tokenTimer?.cancel();
    _client?.onClosed = null;
    _client?.close();
    _client = null;
    _failPending();
  }
}
