import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/finals/finals_invite.dart';
import 'package:shooting_app/finals/finals_net.dart';
import 'package:shooting_app/finals/finals_session_service.dart';
import 'package:shooting_app/models/target_face.dart';
import 'dart:math';

void main() {
  personalDbTest();
  test('код приглашения: кодируется и читается из текста сообщения', () {
    final book = FinalsInviteBook();
    final inv = book.create(role: FinalsRole.athlete, name: 'Иван', targetId: 'u_1');
    final back = FinalsInvite.parse('Приглашаю в финал!\n${inv.encode()}\nдо встречи')!;
    expect(back.token, inv.token);
    expect(back.key, book.key);
    expect(back.role, FinalsRole.athlete);
    expect(back.targetId, 'u_1');
    expect(back.expired, isFalse);
    expect(FinalsInvite.parse('просто текст'), isNull);
  });

  test('токены: принять можно только выданный; после erase приглашения не работают', () {
    final book = FinalsInviteBook();
    final a = book.create(role: FinalsRole.athlete, name: 'A', targetId: 'u_a');
    final j = book.create(role: FinalsRole.coach, name: 'J');
    expect(book.accept('чужой', 'X'), isFalse);
    expect(book.accept(a.token, 'A'), isTrue);
    expect(book.members.firstWhere((m) => m.userId == a.token).status, 'accepted');
    expect(book.chiefHint, isNull); // жюри ещё не подключилось
    book.accept(j.token, 'J');
    expect(book.chiefHint, FinalsInviteBook.hint(j.token));
    // права по токену: участник — только своя мишень, жюри — за любого
    expect(FinalsSessionService.scopeFor(a.token, '', book.members), {'u_a'});
    expect(FinalsSessionService.scopeFor(j.token, '', book.members), isNull);
    book.erase();
    expect(book.accept(a.token, 'A'), isFalse);
    expect(book.members, isEmpty);
  });

  test('хозяин: чужой токен получает denied, после end гости узнают об окончании', () async {
    final book = FinalsInviteBook();
    final inv = book.create(role: FinalsRole.athlete, name: 'A', targetId: 'u_a');
    final (hostCh, guestCh) = MemoryFinalsChannel.pair();
    final fmt = FinalFormat.airRifle10m;
    final c = FinalRunController(
      format: fmt,
      face: TargetFace.byCode(fmt.faceCode),
      engine: FinalEngine(fmt, [for (var i = 0; i < 8; i++) FinalCompetitor(i == 0 ? 'u_a' : 'b$i', 'N$i')]),
      userId: 'u_a',
      bots: const {},
      rng: Random(1),
      manual: true,
    );
    final host = FinalsHost(
      controller: c,
      channel: hostCh,
      allowed: (a) => FinalsSessionService.scopeFor(a, '', book.members),
      onHello: (a, n) => book.accept(a, n),
    );
    final bad = FinalsGuest(channel: guestCh, userId: 'подделка')..hello();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bad.denied, isTrue);
    expect(bad.snapshot, isNull);
    final ok = FinalsGuest(channel: guestCh, userId: inv.token, name: 'A')..hello();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ok.snapshot, isNotNull);
    host.end();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ok.ended, isTrue);
    host.dispose();
  });
}

void personalDbTest() {
  test('приглашение несёт личную базу ведущего', () {
    final book = FinalsInviteBook()
      ..url = 'https://abc.supabase.co'
      ..anonKey = 'sb_publishable_x';
    final inv = book.create(role: FinalsRole.athlete, name: 'A', targetId: 'u_a');
    final back = FinalsInvite.parse(inv.encode())!;
    expect(back.url, 'https://abc.supabase.co');
    expect(back.anonKey, 'sb_publishable_x');
    expect(FinalsInvite.parse(FinalsInviteBook().create(role: FinalsRole.coach, name: 'J').encode())!.url, isNull);
  });
}
