// Экран мессенджера с вошедшим пользователем, контактами и историей
// должен строиться без исключений (в релизной сборке исключение при
// построении = белый/серый экран).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/screens/chat_home_screen.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  testWidgets('группа: автор над сообщением, график отдельной карточкой', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    db.db.execute(
      "INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at, chat_nickname, chat_code) "
      "VALUES (1, 'me', 'tok', ?, 'Я', 'AAAA-BBBB') ON CONFLICT(id) DO UPDATE SET chat_user_id='me', "
      "chat_access_token='tok', chat_expires_at=excluded.chat_expires_at",
      [DateTime.now().add(const Duration(hours: 1)).toIso8601String()],
    );
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(
      id: 'g1',
      nickname: 'Сборная',
      chatCode: '',
      addedAt: DateTime.now(),
      isGroup: true,
      color: '#1E88E5',
      members: const [
        ChatGroupMember(id: 'me', nickname: 'Я', role: 'owner'),
        ChatGroupMember(id: 'u2', nickname: 'Мария'),
      ],
    ));
    repo.addMessage(ChatMessage(
      id: 'x1', clientMessageId: 'c1', contactId: 'g1', senderId: 'u2',
      direction: ChatMessageDirection.incoming, status: ChatMessageStatus.delivered, createdAt: DateTime.now(),
      text: 'Мои серии\n```chart\n{"type":"bar","title":"Серии","x":["1","2"],"series":[{"name":"Очки","values":[97,99]}]}\n```',
    ));
    expect(repo.contactById('g1')!.isGroup, isTrue);
    expect(repo.contactById('g1')!.members, hasLength(2));
    final store = AppDataStore(db)..loadAll();
    await tester.pumpWidget(ChangeNotifierProvider.value(value: store, child: const MaterialApp(home: ChatHomeScreen())));
    await tester.pump();
    expect(find.text('Мария: Мои серии'), findsOneWidget); // превью с автором
    await tester.tap(find.text('Сборная'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.text('Участников: 2'), findsOneWidget);
    expect(find.text('Мария'), findsOneWidget); // автор над пузырём
    expect(find.text('Мои серии'), findsOneWidget); // подпись без блока графика
    expect(find.text('Серии'), findsOneWidget); // заголовок карточки графика
  });
}
