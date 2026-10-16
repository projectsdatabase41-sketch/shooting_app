// Служебная карточка «запрос тренеру» в переписке должна строиться с кнопками
// (отдельный файл: тест с экраном мессенджера плохо уживается с соседним в одном процессе).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/screens/chat_home_screen.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/coach_link.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  testWidgets('переписка: служебная карточка «запрос тренеру» строится с кнопками, а не пустая', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    db.db.execute(
      "INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at, chat_nickname, chat_code, chat_server_url) "
      "VALUES (1, 'me', 'tok', ?, 'Я', 'AAAA-BBBB', '${ChatSettings.url}') ON CONFLICT(id) DO UPDATE SET chat_user_id='me', chat_server_url=excluded.chat_server_url, "
      "chat_access_token='tok', chat_expires_at=excluded.chat_expires_at, chat_nickname='Я', chat_code='AAAA-BBBB'",
      [DateTime.now().add(const Duration(hours: 1)).toIso8601String()],
    );
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(id: 'a', nickname: 'Спортсмен', chatCode: '', addedAt: DateTime.now()));
    repo.addMessage(ChatMessage(
      id: 'm1', clientMessageId: 'c1', contactId: 'a', direction: ChatMessageDirection.incoming,
      text: CoachLink.encode({'k': 'coach_req', 'name': 'Иван Петров', 'birth': '2000-03-15', 'region': 'Москва'}),
      status: ChatMessageStatus.delivered, createdAt: DateTime.now(),
    ));
    final store = AppDataStore(db)..loadAll();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: const MaterialApp(home: ChatHomeScreen()),
    ));
    await tester.pump();
    await tester.tap(find.text('Спортсмен'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.text('Запрос на добавление в спортсмены'), findsWidgets);
    expect(find.text('Иван Петров'), findsOneWidget);
    expect(find.text('Дата рождения: 15.03.2000'), findsOneWidget);
    expect(find.text('Добавить'), findsOneWidget);
    expect(find.text('Отказать'), findsOneWidget);
  });
}
