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
  spectatorTest();
  publicTest();
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

void spectatorTest() {
  test('зритель: кричалка доходит до всех, не чаще раза в 1,5 с, выстрелить зритель не может', () async {
    final book = FinalsInviteBook();
    final spec = book.create(role: FinalsRole.spectator, name: 'Зритель');
    book.accept(spec.token, 'Зритель');
    expect(FinalsSessionService.scopeFor(spec.token, '', book.members), isEmpty);
    expect(FinalsSessionService.canControl(spec.token, '', book.members), isFalse);

    final (hostCh, guestCh) = MemoryFinalsChannel.pair();
    final fmt = FinalFormat.airRifle10m;
    final c = FinalRunController(
      format: fmt,
      face: TargetFace.byCode(fmt.faceCode),
      engine: FinalEngine(fmt, [for (var i = 0; i < 8; i++) FinalCompetitor('b$i', 'N$i')]),
      userId: 'b0',
      bots: const {},
      rng: Random(1),
      manual: true,
    );
    final seenByHost = <String>[];
    final host = FinalsHost(
      controller: c,
      channel: hostCh,
      allowed: (a) => FinalsSessionService.scopeFor(a, '', book.members),
      cheerName: (a) => book.members.where((m) => m.userId == a).map((m) => m.name).firstOrNull,
      onCheer: (n, k) => seenByHost.add('$n:$k'),
    );
    final seenByGuest = <String>[];
    final g = FinalsGuest(channel: guestCh, userId: spec.token, name: 'Зритель')..onCheer = (n, k) => seenByGuest.add('$n:$k');
    g.cheer('clap');
    g.cheer('fire'); // слишком быстро — игнор
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seenByHost, ['Зритель:clap']);
    expect(seenByGuest, ['Зритель:clap']);
    FinalsGuest(channel: guestCh, userId: 'чужой')..cheer('cup');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seenByHost.length, 1);
    host.dispose();
  });
}

void publicTest() {
  test('публичный финал: зрители заходят сами по своему токену до лимита, остальным отказ', () {
    final book = FinalsInviteBook()
      ..isPublic = true
      ..maxSpectators = 2;
    final t = [for (var i = 0; i < 3; i++) newFinalsToken()];
    expect(book.accept(t[0], 'A'), isTrue);
    expect(book.accept(t[1], 'B'), isTrue);
    expect(book.full, isTrue);
    expect(book.accept(t[2], 'C'), isFalse); // мест нет
    expect(book.accept(t[0], 'A'), isTrue); // свой токен работает и при полном зале
    expect(book.accept('коротко', 'X'), isFalse); // мусорный токен
    // зритель из публики не может стрелять
    expect(FinalsSessionService.scopeFor(t[0], '', book.members), isEmpty);
    // непубличный финал чужих не пускает
    expect((FinalsInviteBook()..maxSpectators = 5).accept(newFinalsToken(), 'Z'), isFalse);
  });
}
