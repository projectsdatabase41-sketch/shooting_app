import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/finals_invite.dart';
import 'package:shooting_app/finals/finals_session_service.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  test('уборка: просроченные и оконченные приглашения стираются из сообщений, контакты и чаты целы', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(id: 'coach', nickname: 'Тренер', chatCode: '', addedAt: DateTime.now()));

    final book = FinalsInviteBook();
    final live = book.create(role: FinalsRole.athlete, name: 'A', targetId: 'u_a');
    final old = book.create(role: FinalsRole.athlete, name: 'B', targetId: 'u_b', ttl: const Duration(seconds: -1));
    final done = book.create(role: FinalsRole.athlete, name: 'C', targetId: 'u_c');
    void msg(String id, String text) => db.db.execute(
        "INSERT INTO chat_local_messages (id, client_message_id, contact_id, direction, text) VALUES (?, ?, 'coach', 'incoming', ?)",
        [id, id, text]);
    msg('1', 'Привет, тренировка в 18:00');
    msg('2', 'Приглашаю!\n${live.encode()}');
    msg('3', 'Приглашаю!\n${old.encode()}');
    msg('4', 'Приглашаю!\n${done.encode()}');

    FinalsInviteStore.markEnded(db, done.token);
    expect(FinalsInviteStore.purge(db), 2); // просроченное и оконченное
    String text(String id) => '${db.db.select('SELECT text FROM chat_local_messages WHERE id = ?', [id]).first['text']}';
    expect(text('1'), 'Привет, тренировка в 18:00');
    expect(text('2'), contains(live.token.isEmpty ? '' : FinalsInvite.prefix)); // действующее остаётся
    expect(text('3'), isNot(contains(FinalsInvite.prefix)));
    expect(text('4'), isNot(contains(FinalsInvite.prefix)));
    expect(text('3'), startsWith('Приглашаю!'));
    expect(repo.listContacts().map((c) => c.id), contains('coach')); // тренер на месте
    expect(FinalsInviteStore.pending(db).map((i) => i.token), [live.token]);
    expect(FinalsInviteStore.purge(db), 0);
  });
}
