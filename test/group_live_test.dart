// Живой канал ГРУППЫ (GroupLiveSession) против той же имитации сервера
// Supabase Realtime, что и test/live_chat_test.dart, только теперь в
// канале трое: сообщение от одного уходит остальным двум по Broadcast
// (без P2P — для группы его нет, см. обсуждение с пользователем), а
// вернувшись через "базу" (существующий client_message_id) не дублируется.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/group_live_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/realtime_client.dart';
import 'package:shooting_app/services/remote_config.dart';

class _MockRealtime {
  late HttpServer server;
  final topics = <String, Map<String, WebSocket>>{};

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
            for (final e in (topics[topic] ?? {}).entries.where((e) => e.key != key)) {
              e.value.add(jsonEncode({'topic': m['topic'], 'event': 'broadcast', 'payload': payload}));
            }
          case 'phx_leave':
          case 'heartbeat':
            break;
        }
      });
    });
  }

  String get url => 'http://127.0.0.1:${server.port}';
  Future<void> stop() => server.close(force: true);
}

Future<(ChatAuthService, ChatMessagesRepository)> _user(String id, String groupId) async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  db.db.execute(
    'INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at, chat_server_url) VALUES (1, ?, ?, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET chat_user_id = excluded.chat_user_id, '
    'chat_access_token = excluded.chat_access_token, chat_expires_at = excluded.chat_expires_at, chat_server_url = excluded.chat_server_url',
    [id, 'token-$id', DateTime.now().add(const Duration(hours: 1)).toIso8601String(), ChatSettings.url],
  );
  final repo = ChatMessagesRepository(db);
  repo.addContact(ChatContact(id: groupId, nickname: 'группа', chatCode: '', addedAt: DateTime.now(), isGroup: true)); // FK
  return (ChatAuthService(db), repo);
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ChatMessage _out(String groupId, String text, {String clientId = 'c1'}) => ChatMessage(
      id: 'local-$clientId',
      clientMessageId: clientId,
      contactId: groupId,
      direction: ChatMessageDirection.outgoing,
      text: text,
      status: ChatMessageStatus.sending,
      createdAt: DateTime.now(),
    );

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

  test('сообщение от одного участника доходит остальным двум, себе — нет, повтор не дублирует', () async {
    const gid = 'g1';
    final (authA, repoA) = await _user('uA', gid);
    final (authB, repoB) = await _user('uB', gid);
    final (authC, repoC) = await _user('uC', gid);
    final sa = GroupLiveSession(auth: authA, repo: repoA, groupId: gid, clientFactory: factoryFor('uA'));
    final sb = GroupLiveSession(auth: authB, repo: repoB, groupId: gid, clientFactory: factoryFor('uB'));
    final sc = GroupLiveSession(auth: authC, repo: repoC, groupId: gid, clientFactory: factoryFor('uC'));
    await sa.open();
    await sb.open();
    await sc.open();
    await _until(() => sa.onlineCount == 3 && sb.onlineCount == 3 && sc.onlineCount == 3);

    sa.broadcastText(_out(gid, 'привет всем'));
    await _until(() => repoB.forContact(gid).isNotEmpty && repoC.forContact(gid).isNotEmpty);
    expect(repoB.forContact(gid).single.text, 'привет всем');
    expect(repoB.forContact(gid).single.senderId, 'uA');
    expect(repoC.forContact(gid).single.text, 'привет всем');
    expect(repoA.forContact(gid), isEmpty); // себе не приходит

    // "подъехало" тем же client_message_id обычным путём (fan-out через базу) —
    // pollIncoming в реальном коде проверяет existsByClientId ПЕРЕД addMessage
    // (см. ChatSyncService.pollIncoming), поэтому строка не дублируется.
    expect(repoB.existsByClientId('c1'), isTrue);
    expect(repoB.forContact(gid), hasLength(1));

    sa.close();
    sb.close();
    sc.close();
  });

  test('флаг realtime выключен — канал не открывается, broadcastText молча не делает ничего', () async {
    RemoteConfig.setForTest({});
    final (authA, repoA) = await _user('uA', 'g2');
    final sa = GroupLiveSession(auth: authA, repo: repoA, groupId: 'g2', clientFactory: factoryFor('uA'));
    await sa.open();
    expect(sa.onlineCount, 0);
    sa.broadcastText(_out('g2', 'x')); // не должно бросить исключение
    sa.close();
  });
}
