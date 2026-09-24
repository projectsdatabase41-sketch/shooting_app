import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Минимальный клиент Supabase Realtime (протокол Phoenix, JSON v1) —
/// ровно то, что нужно живому чату: ОДИН приватный канал, Broadcast и
/// Presence. Готового пакета не берём (supabase_flutter потянет за собой
/// весь SDK, а приложение ходит в Supabase голым http).
///
/// Любая ошибка (нет сети, канал не пустили, лимит соединений) — не
/// исключение наружу, а `join() == false` / `onClosed`: вызывающий код
/// просто остаётся на обычном пути через базу.
class RealtimeChannelClient {
  RealtimeChannelClient({
    required this.baseUrl,
    required this.anonKey,
    required this.topic,
    required this.presenceKey,
    this.connect = _defaultConnect,
    this.heartbeat = const Duration(seconds: 25),
    this.joinTimeout = const Duration(seconds: 8),
  });

  final String baseUrl;
  final String anonKey;

  /// Имя канала без префикса `realtime:` (напр. `dm:<a>:<b>`).
  final String topic;

  /// Ключ в Presence — id пользователя.
  final String presenceKey;
  final WebSocketChannel Function(Uri) connect;
  final Duration heartbeat;
  final Duration joinTimeout;

  static WebSocketChannel _defaultConnect(Uri uri) => WebSocketChannel.connect(uri);

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _hb;
  int _ref = 0;
  String? _joinRef;
  final Map<String, Completer<bool>> _pending = {};
  bool _joined = false;
  bool _closed = false;

  /// Кто сейчас в канале (ключи Presence, включая себя).
  final Set<String> peers = {};

  void Function(String event, Map<String, dynamic> payload)? onBroadcast;
  void Function()? onPresenceChanged;
  void Function()? onClosed;

  bool get isJoined => _joined && !_closed;

  String get _fullTopic => 'realtime:$topic';

  /// Подключается и входит в канал. `false` — не получилось (таймаут,
  /// отказ политики RLS, сеть).
  Future<bool> join(String accessToken) async {
    if (_closed) return false;
    try {
      final ws = baseUrl.replaceFirst(RegExp('^http'), 'ws');
      final uri = Uri.parse('$ws/realtime/v1/websocket').replace(queryParameters: {'apikey': anonKey, 'vsn': '1.0.0'});
      _ws = connect(uri);
      await _ws!.ready.timeout(joinTimeout);
      _sub = _ws!.stream.listen(_onData, onDone: _onDone, onError: (_) => _onDone());
      _joinRef = '${++_ref}';
      final ok = _expect(_joinRef!);
      _send(_fullTopic, 'phx_join', {
        'config': {
          'broadcast': {'self': false, 'ack': false},
          'presence': {'key': presenceKey},
          'private': true,
        },
        'access_token': accessToken,
      }, ref: _joinRef);
      final joined = await ok.timeout(joinTimeout, onTimeout: () => false);
      if (!joined) {
        close();
        return false;
      }
      _joined = true;
      _hb = Timer.periodic(heartbeat, (_) => _send('phoenix', 'heartbeat', {}));
      track();
      return true;
    } catch (_) {
      close();
      return false;
    }
  }

  /// «Я в этом диалоге» — виден собеседнику через Presence.
  void track() => _send(_fullTopic, 'presence', {
        'type': 'presence',
        'event': 'track',
        'payload': {'at': DateTime.now().toUtc().toIso8601String()},
      });

  /// Свежий токен для уже открытого канала (токены живут около часа).
  void refreshToken(String accessToken) =>
      _send(_fullTopic, 'access_token', {'access_token': accessToken});

  /// Отправка события собеседнику (без подтверждения от сервера — своё
  /// подтверждение делает `LiveChatSession`).
  bool sendBroadcast(String event, Map<String, dynamic> payload) {
    if (!isJoined) return false;
    _send(_fullTopic, 'broadcast', {'type': 'broadcast', 'event': event, 'payload': payload});
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _joined = false;
    _hb?.cancel();
    _sub?.cancel();
    try {
      _ws?.sink.close();
    } catch (_) {}
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pending.clear();
    peers.clear();
    onClosed?.call();
  }

  Future<bool> _expect(String ref) {
    final c = Completer<bool>();
    _pending[ref] = c;
    return c.future;
  }

  void _send(String topic, String event, Map<String, dynamic> payload, {String? ref}) {
    try {
      _ws?.sink.add(jsonEncode({
        'topic': topic,
        'event': event,
        'payload': payload,
        'ref': ref ?? '${++_ref}',
        'join_ref': _joinRef,
      }));
    } catch (_) {
      close();
    }
  }

  void _onDone() => close();

  void _onData(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      final d = jsonDecode(raw as String);
      if (d is! Map<String, dynamic>) return;
      msg = d;
    } catch (_) {
      return;
    }
    final event = msg['event'];
    final payload = msg['payload'] is Map ? Map<String, dynamic>.from(msg['payload'] as Map) : <String, dynamic>{};
    switch (event) {
      case 'phx_reply':
        final c = _pending.remove('${msg['ref']}');
        c?.complete(payload['status'] == 'ok');
      case 'phx_error':
      case 'phx_close':
        close();
      case 'broadcast':
        final inner = payload['payload'];
        final name = payload['event'];
        if (name is String && inner is Map) onBroadcast?.call(name, Map<String, dynamic>.from(inner));
      case 'presence_state':
        peers
          ..clear()
          ..addAll(payload.keys);
        onPresenceChanged?.call();
      case 'presence_diff':
        final joins = payload['joins'];
        final leaves = payload['leaves'];
        if (joins is Map) peers.addAll(joins.keys.cast<String>());
        if (leaves is Map) peers.removeAll(leaves.keys.cast<String>());
        onPresenceChanged?.call();
    }
  }
}
