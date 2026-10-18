import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/services/chat_auth_service.dart';
import 'package:shooting_app/services/chat_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';

Future<ChatAuthService> _expiredSession(http.Client Function() factory) async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  db.db.execute(
    "INSERT INTO project_settings (id, chat_user_id, chat_access_token, chat_refresh_token, chat_expires_at, chat_nickname, chat_code, chat_server_url) "
    "VALUES (1, 'me', 'tok', 'ref', ?, 'Я', 'AAAA-BBBB', '${ChatSettings.url}') ON CONFLICT(id) DO UPDATE SET chat_user_id='me', chat_server_url=excluded.chat_server_url, "
    "chat_access_token='tok', chat_refresh_token='ref', chat_expires_at=excluded.chat_expires_at",
    [DateTime.now().subtract(const Duration(hours: 1)).toIso8601String()],
  );
  return ChatAuthService(db)..clientFactory = factory;
}

void main() {
  test('обрыв связи при обновлении токена НЕ выкидывает из мессенджера', () async {
    final a = await _expiredSession(() => MockClient((_) async => throw const SocketException('нет сети')));
    expect(await a.ensureFreshToken(), isNull);
    expect(a.isSignedIn, true); // сессия цела
  });

  test('ошибка сервера 503 и лимит 429 — тоже не выход', () async {
    for (final code in [503, 429]) {
      final a = await _expiredSession(() => MockClient((_) async => http.Response('{"msg":"busy"}', code)));
      expect(await a.ensureFreshToken(), isNull);
      expect(a.isSignedIn, true, reason: 'код $code');
    }
  });

  test('сервер отверг refresh-токен (400) — вот тогда выход', () async {
    final a = await _expiredSession(() => MockClient((_) async => http.Response('{"error":"invalid_grant","msg":"Invalid Refresh Token"}', 400)));
    expect(await a.ensureFreshToken(), isNull);
    expect(a.isSignedIn, false);
  });

  test('успешное обновление; параллельные вызовы делают один запрос', () async {
    var calls = 0;
    final a = await _expiredSession(() => MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'ref2', 'expires_in': 3600, 'user': {'id': 'me'}}), 200);
        }));
    final r = await Future.wait([a.ensureFreshToken(), a.ensureFreshToken(), a.ensureFreshToken()]);
    expect(r, ['new', 'new', 'new']);
    expect(calls, 1);
  });

  test('«Выйти из чата» вручную: тихий вход отключён, пока человек сам не войдёт', () async {
    final a = await _expiredSession(() => MockClient((req) async {
          if (req.url.path.contains('/auth/v1/token')) {
            return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 3600, 'user': {'id': 'me'}}), 200);
          }
          return http.Response('[]', 200); // профиль и прочее
        }));
    expect(a.manuallySignedOut, false);
    a.manualSignOut();
    expect(a.isSignedIn, false);
    expect(a.manuallySignedOut, true);
    try {
      await a.signIn(email: 'a@b.c', password: 'pw'); // вход вручную снимает запрет
    } catch (_) {}
    expect(a.manuallySignedOut, false);
    // вынужденный выход (сервер отверг токен) запрет НЕ ставит — тихий вход остаётся
    a.signOutLocally();
    expect(a.manuallySignedOut, false);
  });
}
