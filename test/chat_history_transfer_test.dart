import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_history_transfer.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';

ChatMessage _m(String id, ChatMessageDirection d, String text, {String? b64}) => ChatMessage(
      id: id,
      clientMessageId: 'c$id',
      contactId: 'peer',
      direction: d,
      text: text,
      status: ChatMessageStatus.delivered,
      type: b64 == null ? ChatMessageType.text : ChatMessageType.image,
      attachmentBase64: b64,
      attachmentName: b64 == null ? null : 'a.jpg',
      createdAt: DateTime.utc(2026, 1, int.parse(id)),
    );

void main() {
  test('история собеседника: направление зеркалится, дубли не добавляются, вложение переезжает', () async {
    final theirs = [
      _m('1', ChatMessageDirection.outgoing, 'привет'), // у собеседника «исходящее» = у меня «входящее»
      _m('2', ChatMessageDirection.incoming, 'здорово', b64: 'QUJD'),
    ];
    final json = ChatHistoryTransfer.encode(theirs);

    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(id: 'peer', nickname: 'П', chatCode: '', addedAt: DateTime.now()));
    var n = 0;
    expect(ChatHistoryTransfer.import(repo, 'peer', json, () => 'id${n++}'), 2);
    final got = repo.forContact('peer');
    expect(got.length, 2);
    expect(got[0].direction, ChatMessageDirection.incoming);
    expect(got[1].direction, ChatMessageDirection.outgoing);
    expect(got[1].attachmentBase64, 'QUJD');
    // повторно — ничего нового
    expect(ChatHistoryTransfer.import(repo, 'peer', json, () => 'id${n++}'), 0);
  });
}
