import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';

ChatMessage _m(String id, {String? b64}) => ChatMessage(
      id: id,
      clientMessageId: 'c$id',
      contactId: 'peer',
      direction: ChatMessageDirection.incoming,
      text: 'т$id',
      status: ChatMessageStatus.delivered,
      type: b64 == null ? ChatMessageType.text : ChatMessageType.image,
      attachmentBase64: b64,
      attachmentName: b64 == null ? null : 'a.jpg',
      createdAt: DateTime.utc(2026, 1, int.parse(id)),
    );

void main() {
  test('forContact(reuseFrom) возвращает то же, что полное чтение, включая вложения', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(id: 'peer', nickname: 'П', chatCode: '', addedAt: DateTime.now()));
    repo.addMessage(_m('1'));
    repo.addMessage(_m('2', b64: 'QUJD'));
    final first = repo.forContact('peer');
    repo.addMessage(_m('3', b64: 'REVG')); // новое вложение — читается из БД
    final full = repo.forContact('peer');
    final fast = repo.forContact('peer', reuseFrom: first);
    expect(fast.map((m) => m.id), full.map((m) => m.id));
    expect(fast.map((m) => m.attachmentBase64), full.map((m) => m.attachmentBase64));
    expect(fast.map((m) => m.text), full.map((m) => m.text));
  });
}
