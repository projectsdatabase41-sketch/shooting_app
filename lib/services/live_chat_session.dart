import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'p2p_file_transfer.dart';
import 'push_service.dart' show PushService;
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
/// Как только поднимается прямой WebRTC-датаканал, WS-канал сигнализации
/// закрывается совсем (адрес P2P-пары не меняется, пока соединение живо —
/// держать канал и слать heartbeat незачем). Переоткрывается только если
/// датаканал оборвался — тогда заново заходим в канал, пересигналимся и
/// пробуем поднять P2P снова (не больше [_maxRtcTries] раз за диалог).
///
/// Всё выключено, пока в удалённом конфиге `realtime.enabled = false` —
/// тогда [open] ничего не делает, [trySend] сразу `false`.
class LiveChatSession {
  LiveChatSession({
    required this.auth,
    required this.repo,
    required this.contactId,
    this.onIncoming,
    this.onPeerRead,
    this.ackTimeout = const Duration(seconds: 3),
    this.clientFactory,
    this.linkFactory,
  });

  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final String contactId;

  /// Пришло сообщение по живому каналу (уже сохранено в `repo`).
  void Function()? onIncoming;

  /// Собеседник прочитал наши сообщения (уже отмечено в `repo`) — та же
  /// мгновенная доставка, что у сообщений, только для галочки «прочитано».
  void Function()? onPeerRead;
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

  /// Передача больших файлов напрямую (только когда открыт P2P-канал).
  late final P2pFiles files = P2pFiles(
    send: (e, pl) {
      final l = _link;
      return l != null && l.isOpen && l.send(encodePeerFrame(e, pl));
    },
    dirFor: () async => Directory(p.join((await getApplicationDocumentsDirectory()).path, 'p2p_inbox')),
  )..onBackground = (active, text, progress) => PushService.setTransferActive(active, text: text, progress: progress);
  int _rtcTries = 0;
  static const int _maxRtcTries = 4;

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

  /// Мгновенная отметка «прочитано» присутствующему собеседнику — рядом
  /// с обычной отправкой через базу (`ChatSyncService.reportRead`), не
  /// вместо неё: тут только ускорение для того, кто уже в сети.
  void sendReadReceipt(List<String> clientIds) {
    if (clientIds.isEmpty || !peerOnline) return;
    _emit('read', {'ids': clientIds});
  }

  /// Мгновенное «удалить у всех», пока собеседник в сети — рядом с обычным
  /// сигналом через базу (`ChatSyncService.deleteMessage`), не вместо него.
  void sendDelete(String clientMessageId) {
    if (!peerOnline) return;
    _emit('delete', {'delete_of_client_message_id': clientMessageId});
  }

  /// Реакция на сообщение собеседнику, пока он в сети (рядом с отправкой
  /// через базу, не вместо неё). `emoji == null` — снять.
  void sendReaction(String clientMessageId, String? emoji) {
    if (!peerOnline) return;
    _emit('reaction', {'target_client_message_id': clientMessageId, 'emoji': emoji ?? ''});
  }

  /// Вложение (фото, голос, файл до 8 МБ) напрямую по P2P: без Storage и базы.
  /// `true` — получатель подтвердил приём; иначе вызывающий код грузит как обычно.
  Future<bool> sendAttachmentDirect(ChatMessage m) async {
    final b64 = m.attachmentBase64;
    if (kIsWeb || !isDirect || b64 == null) return false;
    final bytes = base64Decode(b64);
    if (bytes.length > 8 * 1024 * 1024) return false;
    File? f;
    try {
      final dir = await getTemporaryDirectory();
      f = File(p.join(dir.path, 'p2p_out_${m.clientMessageId}'));
      await f.writeAsBytes(bytes, flush: true);
      final s = files.sendFile(
        path: f.path,
        name: m.attachmentName ?? 'file',
        size: bytes.length,
        mime: m.attachmentMime ?? 'application/octet-stream',
        id: m.clientMessageId,
        meta: {
          'att': 1,
          't': m.type.name,
          if (m.text != null) 'cap': m.text,
          if (m.replyToClientMessageId != null) 'rp': m.replyToClientMessageId,
          if (m.replyToPreview != null) 'rv': m.replyToPreview,
          'dl': m.downloadAllowed,
        },
      );
      final done = Completer<bool>();
      void check() {
        if (done.isCompleted) return;
        final st = s.state.value;
        if (st == P2pState.done) done.complete(true);
        if (st == P2pState.failed || st == P2pState.rejected || st == P2pState.cancelled) done.complete(false);
      }

      s.state.addListener(check);
      check();
      final ok = await done.future.timeout(Duration(seconds: 15 + bytes.length ~/ 100000), onTimeout: () {
        s.cancel();
        return false;
      });
      s.state.removeListener(check);
      return ok;
    } catch (_) {
      return false;
    } finally {
      try {
        await f?.delete();
      } catch (_) {}
    }
  }

  /// Сигналы звонка (ring / offer / answer / ice / join / hangup …) по тому же
  /// каналу: сначала прямой P2P, иначе Realtime. Сервер звонков не нужен.
  void Function(Map<String, dynamic> p)? onCall;
  bool sendCall(Map<String, dynamic> p) => peerOnline && _emit('call', p);

  void _onBroadcast(String event, Map<String, dynamic> p) {
    if (event == 'call') {
      onCall?.call(p);
      return;
    }
    if (P2pFiles.isFileEvent(event)) {
      files.handle(event, p);
      return;
    }
    if (event == 'reaction') {
      final id = p['target_client_message_id'];
      final emoji = p['emoji'];
      if (id is String && id.isNotEmpty && emoji is String && emoji.length <= 16) {
        repo.setReaction(id, contactId, emoji.isEmpty ? null : emoji);
        onPeerRead?.call();
      }
      return;
    }
    if (event == 'read') {
      final ids = p['ids'];
      if (ids is List) {
        repo.markPeerRead(contactId, [for (final id in ids) '$id']);
        onPeerRead?.call();
      }
      return;
    }
    if (event == 'delete') {
      final id = p['delete_of_client_message_id'];
      // Собеседник мог уже удалить его сам (у себя) — тогда byClientId не
      // найдёт строку, и это просто тихо ничего не делает, без ошибки.
      if (id is String && id.isNotEmpty) {
        final target = repo.byClientId(contactId, id);
        if (target != null) repo.deleteMessage(target.id);
        onPeerRead?.call(); // перерисовать ленту, без звука нового сообщения
      }
      return;
    }
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
      if (_link != l) return;
      if (l.isOpen) {
        _restIdle();
        return;
      }
      _link = null;
      files.abortAll(); // передачи по оборванному P2P останавливаем
      if (_closed) return;
      // Канал сигнализации мог быть закрыт «на отдыхе» (P2P и так работал) —
      // поднимаем его заново; presence подскажет, когда пробовать P2P снова.
      if (_client == null) {
        open();
      } else {
        _maybeStartRtc(); // не более _maxRtcTries попыток за диалог
      }
    };
    return l;
  }

  /// P2P установлен — WS-канал сигнализации (и его heartbeat) больше не
  /// нужен, пока соединение живо. Переоткроется сам, если P2P оборвётся.
  void _restIdle() {
    _retry?.cancel();
    _tokenTimer?.cancel();
    final c = _client;
    _client = null;
    c?.onClosed = null;
    c?.close();
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
    files.abortAll();
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

/// Живые соединения открытых переписок: выход из чата в список мессенджера
/// НЕ рвёт соединение сразу (особенно P2P — заново поднимать его долго), оно
/// живёт ещё [grace], пока пользователь не вернётся. Закрывается целиком, когда
/// мессенджер закрыт (`closeAll`) и когда приложение свёрнуто — иначе собеседник
/// получал бы «доставлено» без push, а пользователь не видел сообщения.
class LiveSessions {
  LiveSessions._();

  static final _sessions = <String, LiveChatSession>{};
  static final _timers = <String, Timer>{};
  static bool _observing = false;

  static LiveChatSession acquire(String contactId, LiveChatSession Function() create) {
    _observe();
    _timers.remove(contactId)?.cancel();
    return _sessions.putIfAbsent(contactId, () {
      final s = create();
      s.open();
      return s;
    });
  }

  /// Экран закрыт: отцепляем его обработчики, соединение оставляем на [grace].
  static void release(String contactId, {Duration grace = const Duration(minutes: 3)}) {
    final s = _sessions[contactId];
    if (s == null) return;
    s.onIncoming = null;
    s.onPeerRead = null;
    s.files.onOffer = null;
    s.files.onChanged = null;
    _timers.remove(contactId)?.cancel();
    _timers[contactId] = Timer(grace, () => close(contactId));
  }

  static void close(String contactId) {
    _timers.remove(contactId)?.cancel();
    final s = _sessions[contactId];
    if (s == null) return;
    // Идёт передача файла напрямую — соединение держим (в том числе в фоне),
    // повторная проверка через несколько секунд.
    if (s.files.hasActive) {
      _timers[contactId] = Timer(const Duration(seconds: 10), () => close(contactId));
      return;
    }
    _sessions.remove(contactId);
    s.close();
  }

  static void closeAll() {
    final busy = [for (final e in _sessions.entries) if (e.value.files.hasActive) e.key];
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final idle = [for (final e in _sessions.entries) if (!busy.contains(e.key)) e.key];
    for (final id in idle) {
      _sessions.remove(id)?.close();
    }
    // Соединения с идущей передачей остаются; закроем, когда она закончится.
    for (final id in busy) {
      _timers[id] = Timer(const Duration(seconds: 10), () => close(id));
    }
  }

  static void _observe() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(_LifecycleObserver());
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) LiveSessions.closeAll();
  }
}
