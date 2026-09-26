// Экран мессенджера с вошедшим пользователем, контактами и историей
// должен строиться без исключений (в релизной сборке исключение при
// построении = белый/серый экран).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/models/chat_contact.dart';
import 'package:shooting_app/models/chat_message.dart';
import 'package:shooting_app/screens/chat_home_screen.dart';
import 'package:shooting_app/screens/chat_thread_screen.dart';
import 'package:shooting_app/services/chat_messages_repository.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  testWidgets('список собеседников строится', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    db.db.execute(
      "INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_expires_at, chat_nickname, chat_code, chat_server_url) "
      "VALUES (1, 'me', 'tok', ?, 'Я', 'AAAA-BBBB', '${ChatSettings.url}') ON CONFLICT(id) DO UPDATE SET chat_user_id='me', chat_server_url=excluded.chat_server_url, "
      "chat_access_token='tok', chat_expires_at=excluded.chat_expires_at, chat_nickname='Я', chat_code='AAAA-BBBB'",
      [DateTime.now().add(const Duration(hours: 1)).toIso8601String()],
    );
    final repo = ChatMessagesRepository(db);
    repo.addContact(ChatContact(id: 'a', nickname: 'Иван Петров', chatCode: '', about: 'Клуб Динамо', addedAt: DateTime.now()));
    repo.addContact(ChatContact(id: 'b', nickname: 'Без истории', chatCode: '', addedAt: DateTime.now()));
    for (final (i, t) in [DateTime.now(), DateTime(2026, 1, 5), DateTime(2024, 3, 1)].indexed) {
      repo.addMessage(ChatMessage(
        id: 'm$i', clientMessageId: 'c$i', contactId: 'a', direction: ChatMessageDirection.incoming,
        text: 'привет $i', status: ChatMessageStatus.delivered, createdAt: t,
      ));
    }
    final store = AppDataStore(db)..loadAll();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: const MaterialApp(home: ChatHomeScreen()),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Иван Петров'), findsOneWidget);
    expect(find.text('Без истории'), findsNothing); // на главном — только переписки
    // шторка слева → Контакты
    await tester.tap(find.byTooltip('Меню'));
    await tester.pumpAndSettle();
    expect(find.text('Код: AAAA-BBBB'), findsOneWidget);
    await tester.tap(find.text('Контакты'));
    await tester.pumpAndSettle();
    expect(find.text('Без истории'), findsOneWidget); // в «Контактах» — все
    expect(find.byIcon(Icons.add), findsOneWidget); // «+» → все участники
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Иван Петров'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(ChatThreadScreen), findsOneWidget);
    expect(find.text('Клуб Динамо'), findsOneWidget); // «о себе» в шапке
    expect(find.text('привет 0'), findsOneWidget);
  });
}
