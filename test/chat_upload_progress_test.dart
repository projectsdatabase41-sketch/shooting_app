// Загрузка вложения в retry() — теперь потоковая (StreamedRequest), с
// прогрессом в ChatSyncService.uploadProgress вместо одного blocking POST.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/chat_sync_service.dart';
import 'package:shooting_app/services/local_db_service.dart';

Future<(ChatAuthService, ChatMessagesRepository)> _user(String id, String peer) async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  db.db.execute(
    'INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at, chat_server_url) VALUES (1, ?, ?, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET chat_user_id = excluded.chat_user_id, '
    'chat_access_token = excluded.chat_access_token, chat_expires_at = excluded.chat_expires_at, chat_server_url = excluded.chat_server_url',
    [id, 'token-$id', DateTime.now().add(const Duration(hours: 1)).toIso8601String(), ChatSettings.url],
  );
  final repo = ChatMessagesRepository(db);
  repo.addContact(ChatContact(id: peer, nickname: peer, chatCode: '', addedAt: DateTime.now()));
  return (ChatAuthService(db), repo);
}

ChatMessage _photo(String contactId, List<int> bytes, {String clientId = 'c1'}) => ChatMessage(
      id: 'local-$clientId',
      clientMessageId: clientId,
      contactId: contactId,
      direction: ChatMessageDirection.outgoing,
      status: ChatMessageStatus.sending,
      type: ChatMessageType.image,
      attachmentBase64: base64Encode(bytes),
      attachmentName: 'photo.jpg',
      attachmentMime: 'image/jpeg',
      attachmentSize: bytes.length,
      createdAt: DateTime.now(),
    );

void main() {
  test('прогресс растёт по ходу отправки и пропадает по завершении; статус — sent', () async {
    final (auth, repo) = await _user('uA', 'uB');
    final progressSeen = <double>[];
    void listener() {
      final p = ChatSyncService.uploadProgress.value['c1'];
      if (p != null) progressSeen.add(p);
    }

    ChatSyncService.uploadProgress.addListener(listener);
    final client = MockClient((req) async {
      if (req.url.path.contains('/storage/')) return http.Response('', 200);
      return http.Response('', 200); // запись сообщения
    });
    final sync = ChatSyncService(auth, repo, clientFactory: () => client);

    final bytes = List<int>.filled(200 * 1024, 7); // несколько чанков по 32КБ
    final m = _photo('uB', bytes);
    repo.addMessage(m);
    await sync.retry(m);

    expect(progressSeen, isNotEmpty);
    expect(progressSeen.last, 1.0);
    expect(progressSeen, orderedEquals(List<double>.from(progressSeen)..sort())); // монотонно растёт
    expect(ChatSyncService.uploadProgress.value.containsKey('c1'), isFalse); // прибрано после
    expect(repo.forContact('uB').single.status, ChatMessageStatus.sent);
    ChatSyncService.uploadProgress.removeListener(listener);
  });

  test('сбой загрузки — прогресс всё равно убирается (finally), статус error', () async {
    final (auth, repo) = await _user('uA', 'uB');
    final client = MockClient((req) async {
      if (req.url.path.contains('/storage/')) return http.Response('нет места', 500);
      return http.Response('', 200);
    });
    final sync = ChatSyncService(auth, repo, clientFactory: () => client);
    final m = _photo('uB', List<int>.filled(1024, 1), clientId: 'c2');
    repo.addMessage(m);
    await expectLater(sync.retry(m), throwsA(anything));
    expect(ChatSyncService.uploadProgress.value.containsKey('c2'), isFalse);
    expect(repo.forContact('uB').single.status, ChatMessageStatus.error);
  });
}
