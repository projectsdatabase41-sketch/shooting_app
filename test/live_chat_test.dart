// Живой канал чата (RealtimeChannelClient + LiveChatSession) против
// имитации сервера Supabase Realtime (протокол Phoenix, JSON v1): она
// принимает join, ведёт Presence и пересылает Broadcast другому участнику
// канала — ровно настолько, насколько нужно клиенту. Проверяет
// согласованность клиента с протоколом как мы его знаем, НЕ настоящий
// Supabase (для него нужны два реальных устройства).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/live_chat_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/peer_link.dart';
import 'package:shooting_app/services/realtime_client.dart';
import 'package:shooting_app/services/remote_config.dart';

class _MockRealtime {
  late HttpServer server;
  final topics = <String, Map<String, WebSocket>>{};
  bool rejectJoin = false;
  bool dropBroadcast = false;
  int msgBroadcasts = 0; // сколько 'msg' прошло через сервер
  final joinPayloads = <Map<String, dynamic>>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      String? topic;
      String? key;
      ws.listen((raw) {
        final m = jsonDecode(raw as String) as Map<String, dynamic>;
        final payload = (m['payload'] as Map).cast<String, dynamic>();
        void reply(bool ok) => ws.add(jsonEncode({
              'topic': m['topic'],
              'event': 'phx_reply',
              'ref': m['ref'],
              'payload': {'status': ok ? 'ok' : 'error', 'response': {}},
            }));
        switch (m['event']) {
          case 'phx_join':
            if (rejectJoin) return reply(false);
            joinPayloads.add(payload);
            topic = (m['topic'] as String).substring('realtime:'.length);
            key = ((payload['config'] as Map)['presence'] as Map)['key'] as String;
            final room = topics.putIfAbsent(topic!, () => {});
            room[key!] = ws;
            reply(true);
            ws.add(jsonEncode({
              'topic': m['topic'],
              'event': 'presence_state',
              'payload': {for (final k in room.keys) k: {'metas': []}},
            }));
            for (final e in room.entries.where((e) => e.key != key)) {
              e.value.add(jsonEncode({
                'topic': m['topic'],
                'event': 'presence_diff',
                'payload': {'joins': {key: {'metas': []}}, 'leaves': {}},
              }));
            }
          case 'broadcast':
            if (payload['event'] == 'msg') msgBroadcasts++;
            if (dropBroadcast) return;
            for (final e in (topics[topic] ?? {}).entries.where((e) => e.key != key)) {
              e.value.add(jsonEncode({'topic': m['topic'], 'event': 'broadcast', 'payload': payload}));
            }
          case 'phx_leave':
          case 'heartbeat':
            break;
        }
      }, onDone: () {
        final room = topics[topic];
        if (room == null) return;
        room.remove(key);
        for (final e in room.values) {
          e.add(jsonEncode({
            'topic': 'realtime:$topic',
            'event': 'presence_diff',
            'payload': {'joins': {}, 'leaves': {key: {'metas': []}}},
          }));
        }
      });
    });
  }

  String get url => 'http://127.0.0.1:${server.port}';
  Future<void> stop() => server.close(force: true);
}

Future<(ChatAuthService, ChatMessagesRepository)> _user(String id, String peer) async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  db.db.execute(
    'INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at) VALUES (1, ?, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET chat_user_id = excluded.chat_user_id, '
    'chat_access_token = excluded.chat_access_token, chat_expires_at = excluded.chat_expires_at',
    [id, 'token-$id', DateTime.now().add(const Duration(hours: 1)).toIso8601String()],
  );
  final repo = ChatMessagesRepository(db);
  repo.addContact(ChatContact(id: peer, nickname: peer, chatCode: '', addedAt: DateTime.now())); // FK на chat_contacts
  return (ChatAuthService(db), repo);
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ChatMessage _out(String contactId, String text, {String clientId = 'c1'}) => ChatMessage(
      id: 'local-$clientId',
      clientMessageId: clientId,
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      text: text,
      status: ChatMessageStatus.sending,
      createdAt: DateTime.now(),
    );

/// Подмена WebRTC: линки в паре «соединяются» после offer/answer, кадры
/// идут напрямую друг другу — сервер их не видит.
class _FakeLink implements PeerLink {
  static final List<_FakeLink> created = [];
  _FakeLink() {
    created.add(this);
  }
  _FakeLink? other;
  bool open = false;
  bool started = false;
  void Function(String)? _msg;
  void Function()? _state;
  void Function(Map<String, dynamic>)? _sig;
  @override
  bool get isOpen => open;
  @override
  set onMessage(void Function(String)? cb) => _msg = cb;
  @override
  set onState(void Function()? cb) => _state = cb;
  @override
  set onSignal(void Function(Map<String, dynamic>)? cb) => _sig = cb;
  @override
  Future<void> start({required bool initiator}) async {
    started = true;
    if (initiator) _sig?.call({'kind': 'offer', 'sdp': 'x'});
  }

  @override
  Future<void> handleSignal(Map<String, dynamic> s) async {
    if (s['kind'] == 'offer') {
      _sig?.call({'kind': 'answer', 'sdp': 'y'});
      open = true;
      _state?.call();
    } else if (s['kind'] == 'answer') {
      open = true;
      _state?.call();
    }
  }

  @override
  bool send(String data) {
    if (!open || other == null) return false;
    other!._msg?.call(data);
    return true;
  }

  @override
  void close() {
    final was = open;
    open = false;
    if (was) _state?.call();
  }
}

PeerLink _pairedFake() {
  final l = _FakeLink();
  if (_FakeLink.created.length.isEven) {
    final prev = _FakeLink.created[_FakeLink.created.length - 2];
    l.other = prev;
    prev.other = l;
  }
  return l;
}

void main() {
  late _MockRealtime server;
  setUp(() async {
    server = _MockRealtime();
    await server.start();
    RemoteConfig.setForTest({'realtime': {'enabled': true}});
  });
  tearDown(() async {
    RemoteConfig.setForTest({});
    await server.stop();
  });

  RealtimeChannelClient Function(String) factoryFor(String uid) => (topic) =>
      RealtimeChannelClient(baseUrl: server.url, anonKey: 'anon', topic: topic, presenceKey: uid);

  test('join: приватный канал с токеном, presence виден обоим', () async {
    final a = RealtimeChannelClient(baseUrl: server.url, anonKey: 'k', topic: 'dm:a:b', presenceKey: 'a');
    final b = RealtimeChannelClient(baseUrl: server.url, anonKey: 'k', topic: 'dm:a:b', presenceKey: 'b');
    expect(await a.join('tok-a'), isTrue);
    expect(await b.join('tok-b'), isTrue);
    await _until(() => a.peers.contains('b'));
    expect(a.peers, containsAll(['a', 'b']));
    expect(server.joinPayloads.first['private'], isNull); // приватность — внутри config
    final cfg = server.joinPayloads.first['config'] as Map;
    expect(cfg['private'], isTrue);
    expect(server.joinPayloads.first['access_token'], 'tok-a');
    b.close();
    await _until(() => !a.peers.contains('b'));
    expect(a.peers, ['a']);
    a.close();
  });

  test('отказ сервера (RLS/лимит) → join false, без исключений', () async {
    server.rejectJoin = true;
    final a = RealtimeChannelClient(baseUrl: server.url, anonKey: 'k', topic: 'dm:a:b', presenceKey: 'a');
    expect(await a.join('t'), isFalse);
    expect(a.isJoined, isFalse);
  });

  test('недоступный сервер → join false', () async {
    final a = RealtimeChannelClient(baseUrl: 'http://127.0.0.1:1', anonKey: 'k', topic: 't', presenceKey: 'a');
    expect(await a.join('t'), isFalse);
  });

  test('сообщение идёт напрямую, получатель сохраняет и подтверждает, повтор не дублируется', () async {
    final (authA, repoA) = await _user('uA', 'uB');
    final (authB, repoB) = await _user('uB', 'uA');
    var incomingB = 0;
    final sa = LiveChatSession(auth: authA, repo: repoA, contactId: 'uB', clientFactory: factoryFor('uA'));
    final sb = LiveChatSession(
        auth: authB, repo: repoB, contactId: 'uA', clientFactory: factoryFor('uB'), onIncoming: () => incomingB++);
    await sa.open();
    await sb.open();
    await _until(() => sa.peerOnline && sb.peerOnline);
    expect(sa.topic, sb.topic);

    final m = _out('uB', 'привет');
    repoA.addMessage(m);
    expect(await sa.trySend(m), isTrue);
    expect(repoB.forContact('uA').single.text, 'привет');
    expect(repoB.forContact('uA').single.direction, ChatMessageDirection.incoming);
    expect(incomingB, 1);
    expect(repoA.forContact('uB').single.status, ChatMessageStatus.delivered);

    // повторная отправка того же client_message_id — дубля нет, ack есть
    expect(await sa.trySend(m), isTrue);
    expect(repoB.forContact('uA'), hasLength(1));
    expect(incomingB, 1);
    sa.close();
    sb.close();
  });

  test('нет подтверждения за таймаут → false (вызывающий уйдёт через базу)', () async {
    final (authA, repoA) = await _user('uA', 'uB');
    final (authB, repoB) = await _user('uB', 'uA');
    final sa = LiveChatSession(
        auth: authA, repo: repoA, contactId: 'uB', ackTimeout: const Duration(milliseconds: 200), clientFactory: factoryFor('uA'));
    final sb = LiveChatSession(auth: authB, repo: repoB, contactId: 'uA', clientFactory: factoryFor('uB'));
    await sa.open();
    await sb.open();
    await _until(() => sa.peerOnline);
    server.dropBroadcast = true;
    final m = _out('uB', 'потеряется');
    repoA.addMessage(m);
    expect(await sa.trySend(m), isFalse);
    expect(repoA.forContact('uB').single.status, ChatMessageStatus.sending);
    sa.close();
    sb.close();
  });

  test('собеседника нет в канале, вложение или флаг выключен → сразу false', () async {
    final (authA, repoA) = await _user('uA', 'uB');
    final sa = LiveChatSession(auth: authA, repo: repoA, contactId: 'uB', clientFactory: factoryFor('uA'));
    await sa.open();
    expect(sa.peerOnline, isFalse);
    expect(await sa.trySend(_out('uB', 'один')), isFalse);
    final photo = ChatMessage(
      id: 'p',
      clientMessageId: 'p',
      contactId: 'uB',
      direction: ChatMessageDirection.outgoing,
      status: ChatMessageStatus.sending,
      type: ChatMessageType.image,
      createdAt: DateTime.now(),
    );
    expect(await sa.trySend(photo), isFalse);
    sa.close();

    RemoteConfig.setForTest({}); // флаг выключен
    final joinsBefore = server.joinPayloads.length;
    final off = LiveChatSession(auth: authA, repo: repoA, contactId: 'uB', clientFactory: factoryFor('uA'));
    await off.open();
    expect(server.joinPayloads.length, joinsBefore); // к серверу не подключались
    expect(await off.trySend(_out('uB', 'x')), isFalse);
  });

  test('мусор от собеседника (пустой текст, огромный текст, без id) игнорируется', () async {
    final (authB, repoB) = await _user('uB', 'uA');
    final sb = LiveChatSession(auth: authB, repo: repoB, contactId: 'uA', clientFactory: factoryFor('uB'));
    await sb.open();
    final raw = RealtimeChannelClient(baseUrl: server.url, anonKey: 'k', topic: sb.topic, presenceKey: 'uA');
    await raw.join('t');
    await _until(() => raw.peers.contains('uB'));
    raw.sendBroadcast('msg', {'client_message_id': 'x1', 'text': ''});
    raw.sendBroadcast('msg', {'client_message_id': 'x2', 'text': 'я' * 9000});
    raw.sendBroadcast('msg', {'text': 'без id'});
    raw.sendBroadcast('другое', {'client_message_id': 'x3', 'text': 'не msg'});
    raw.sendBroadcast('msg', {'client_message_id': 'ok', 'text': 'нормально'});
    await _until(() => repoB.forContact('uA').isNotEmpty);
    expect(repoB.forContact('uA').map((m) => m.text), ['нормально']);
    raw.close();
    sb.close();
  });

  test('WebRTC: линк поднимается, сообщения идут мимо сервера; без флага — через Broadcast', () async {
    _FakeLink.created.clear();
    RemoteConfig.setForTest({'realtime': {'enabled': true}, 'webrtc': {'enabled': true}});
    final (authA, repoA) = await _user('uA', 'uB');
    final (authB, repoB) = await _user('uB', 'uA');
    final sa = LiveChatSession(
        auth: authA, repo: repoA, contactId: 'uB', clientFactory: factoryFor('uA'), linkFactory: _pairedFake);
    final sb = LiveChatSession(
        auth: authB, repo: repoB, contactId: 'uA', clientFactory: factoryFor('uB'), linkFactory: _pairedFake);
    await sa.open();
    await sb.open();
    await _until(() => sa.isDirect && sb.isDirect);
    expect(sa.isDirect && sb.isDirect, isTrue);
    expect(_FakeLink.created, hasLength(2)); // начал только uA (id меньше), uB ответил

    final m = _out('uB', 'напрямую');
    repoA.addMessage(m);
    expect(await sa.trySend(m), isTrue);
    expect(repoB.forContact('uA').single.text, 'напрямую');
    expect(server.msgBroadcasts, 0);

    // прямой канал оборвался → тот же диалог продолжает работать через Broadcast
    _FakeLink.created[0].close();
    _FakeLink.created[1].open = false;
    final m2 = _out('uB', 'через сервер', clientId: 'c2');
    repoA.addMessage(m2);
    await _until(() => sa.peerOnline);
    expect(await sa.trySend(m2), isTrue);
    expect(server.msgBroadcasts, 1);
    expect(repoB.forContact('uA'), hasLength(2));
    sa.close();
    sb.close();
  });

  test('WebRTC выключен флагом — линки не создаются', () async {
    _FakeLink.created.clear();
    final (authA, repoA) = await _user('uA', 'uB');
    final (authB, repoB) = await _user('uB', 'uA');
    final sa = LiveChatSession(
        auth: authA, repo: repoA, contactId: 'uB', clientFactory: factoryFor('uA'), linkFactory: _pairedFake);
    final sb = LiveChatSession(
        auth: authB, repo: repoB, contactId: 'uA', clientFactory: factoryFor('uB'), linkFactory: _pairedFake);
    await sa.open();
    await sb.open();
    await _until(() => sa.peerOnline);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(_FakeLink.created, isEmpty);
    sa.close();
    sb.close();
  });
}
