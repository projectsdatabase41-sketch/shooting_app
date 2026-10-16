import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/chat_sync_service.dart';
import 'package:shooting_app/services/coach_access_service.dart';
import 'package:shooting_app/services/coach_link.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  test('карточки: разбор, превью вместо сырого JSON', () {
    final t = CoachLink.encode({'k': 'coach_req', 'name': 'Иван Петров'});
    expect(CoachLink.isCard(t), isTrue);
    expect(CoachLink.parse(t)!['name'], 'Иван Петров');
    expect(CoachLink.preview(t), 'Запрос на добавление в спортсмены');
    expect(CoachLink.isCard('обычный текст'), isFalse);
    expect(CoachLink.parse('NX1:{не json'), isNull);
  });

  test('тренер: пришёл доступ → спортсмен сохранён в списке, повтор не дублирует', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final auth = ChatAuthService(db);
    final repo = ChatMessagesRepository(db);
    final link = CoachLink(db: db, auth: auth, repo: repo, sync: ChatSyncService(auth, repo));
    repo.addMessage(ChatMessage(
      id: 'm1',
      clientMessageId: 'c1',
      contactId: 'athlete1',
      direction: ChatMessageDirection.incoming,
      text: CoachLink.encode({'k': 'coach_grant', 'url': 'https://x.supabase.co', 'anon': 'anon-key', 'token': 'tok', 'name': 'Иван Петров'}),
      status: ChatMessageStatus.delivered,
      createdAt: DateTime.now(),
    ));
    final store = AppDataStore(db);
    expect(await link.processIncoming(store), 1);
    final list = CoachAccessService(db).listAthletes();
    expect(list.length, 1);
    expect(list.first.name, 'Иван Петров');
    expect(list.first.token, 'tok');
    expect(link.state('c1'), 'done');
    expect(await link.processIncoming(store), 0); // идемпотентно
    expect(CoachAccessService(db).listAthletes().length, 1);
  });
}
