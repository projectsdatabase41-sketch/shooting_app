import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/final_engine.dart';
import 'package:shooting_app/finals/final_run.dart';
import 'package:shooting_app/finals/finals_bridge.dart';
import 'package:shooting_app/finals/finals_net.dart';
import 'package:shooting_app/finals/local_link.dart';
import 'package:shooting_app/models/target_face.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 60));

FinalRunController _ctl() {
  final fmt = FinalFormat.airRifle10m;
  return FinalRunController(
    format: fmt,
    face: TargetFace.byCode(fmt.faceCode),
    engine: FinalEngine(fmt, [for (var i = 0; i < 8; i++) FinalCompetitor(i == 0 ? 'u_a' : 'b$i', 'N$i')]),
    userId: 'u_a',
    bots: const {},
    rng: Random(1),
    manual: true,
  );
}

void main() {
  hostModeTest();
  test('кадрирование: большое сообщение режется на пакеты и собирается обратно без потерь', () {
    final tx = MessageFramer(maxPacket: 100), rx = MessageFramer(maxPacket: 100);
    final big = {'rows': [for (var i = 0; i < 30; i++) {'id': 'u_$i', 'name': 'Участник номер $i', 'pts': List.generate(10, (k) => [k * 1.5, -k * 0.7])}]};
    final frames = tx.encode('state', big)!;
    expect(frames.length, greaterThan(10));
    expect(frames.every((f) => f.length <= 100), isTrue);
    Map<String, dynamic>? got;
    String? ev;
    for (final f in frames.reversed.take(1).followedBy(frames.take(frames.length - 1))) {
      rx.feed(f, (e, p) {
        ev = e;
        got = p;
      });
    }
    expect(ev, 'state');
    expect(got, big, reason: 'порядок частей внутри сообщения не важен');
  });

  test('кадрирование: оборванное сообщение отбрасывается целиком, следующее собирается', () {
    final tx = MessageFramer(maxPacket: 24), rx = MessageFramer(maxPacket: 24);
    final first = tx.encode('state', {'a': 'x' * 100})!;
    final second = tx.encode('state', {'b': 'y' * 50})!;
    final out = <Map<String, dynamic>>[];
    for (final f in first.take(first.length - 1)) {
      rx.feed(f, (e, p) => out.add(p)); // последняя часть первого потерялась
    }
    for (final f in second) {
      rx.feed(f, (e, p) => out.add(p));
    }
    expect(out, [{'b': 'y' * 50}]);
    expect(MessageFramer(maxPacket: 5).encode('x', {'z': 1}), isNull, reason: 'пакет без места под данные — не отправляем');
    expect(tx.encode('x', {'z': 'q' * 10000}), isNotNull, reason: 'длинное сообщение режется на сотни кадров');
  });

  test('канал поверх локальной связи: те же send/onMessage, что у realtime', () async {
    final (la, lb) = MemoryLocalLink.pair(maxPacket: 32);
    final a = LocalLinkChannel(la), b = LocalLinkChannel(lb);
    final got = <String>[];
    b.onMessage = (e, p) => got.add('$e:${p['k']}');
    expect(a.send('shot', {'k': 'ключ-' * 20}), isTrue);
    await _settle();
    expect(got, ['shot:${'ключ-' * 20}']);
    la.close();
    expect(a.send('x', {}), isFalse);
  });

  test('мост тира: устройство без сети получает состояние ведущего и стреляет через мост', () async {
    final c = _ctl();
    c.advance();
    c.advance(); // старт: можно ставить выстрелы
    final (hostCh, bridgeUp) = MemoryFinalsChannel.pair();
    final host = FinalsHost(controller: c, channel: hostCh, allowed: (_) => null);
    final bridge = FinalsBridge(bridgeUp);

    // локальное устройство соединено с мостом «по Bluetooth» (в тесте — связь в памяти с мелкими пакетами)
    final (linkBridgeSide, linkClient) = MemoryLocalLink.pair(maxPacket: 64);
    bridge.addLocal(LocalLinkChannel(linkBridgeSide));
    expect(bridge.localCount, 1);
    final guest = FinalsGuest(channel: LocalLinkChannel(linkClient), userId: 'tok')..hello();
    await _settle();
    await _settle();
    expect(guest.snapshot, isNotNull, reason: 'состояние дошло: ведущий → база → мост → Bluetooth → устройство');
    expect(guest.snapshot!.data['rid'], c.roundId);

    guest.shoot('u_a', 1.5, -2.0);
    await _settle();
    await _settle();
    expect(c.stagedOf('u_a').length, 1, reason: 'выстрел дошёл до ведущего через мост');

    // позднее подключившееся устройство получает кеш моста сразу
    final (l2, c2) = MemoryLocalLink.pair(maxPacket: 64);
    bridge.addLocal(LocalLinkChannel(l2));
    final late = FinalsGuest(channel: LocalLinkChannel(c2), userId: 'tok2');
    await _settle();
    expect(late.snapshot, isNotNull);

    host.end();
    await _settle();
    await _settle();
    expect(guest.ended, isTrue);
    host.dispose();
    bridge.close();
  });

  test('сам мост тоже участник: его экран получает сообщения и шлёт в базу', () async {
    final (hostCh, bridgeUp) = MemoryFinalsChannel.pair();
    final bridge = FinalsBridge(bridgeUp);
    final fromHost = <String>[];
    bridge.self.onMessage = (e, p) => fromHost.add(e);
    final atHost = <String>[];
    hostCh.onMessage = (e, p) => atHost.add(e);
    hostCh.send('state', {'x': 1});
    bridge.self.send('hello', {'author': 'мост'});
    await _settle();
    expect(fromHost, ['state']);
    expect(atHost, ['hello']);
    bridge.close();
    // Uint8List импортирован для явности типа кадров
    expect(Uint8List(0), isEmpty);
  });
}

void hostModeTest() {
  test('мост в режиме ведущего: устройства тира говорят с ведущим напрямую, его состояние идёт и в сеть, и им', () async {
    final c = _ctl();
    c.advance();
    c.advance();
    final (netCh, remote) = MemoryFinalsChannel.pair(); // «база» и удалённый участник
    final hub = FinalsBridge(netCh, hostMode: true);
    final host = FinalsHost(controller: c, channel: hub.self, allowed: (_) => null);
    final remoteGuest = FinalsGuest(channel: remote, userId: 'remote')..hello();
    final (lh, lc) = MemoryLocalLink.pair(maxPacket: 64);
    hub.addLocal(LocalLinkChannel(lh));
    final local = FinalsGuest(channel: LocalLinkChannel(lc), userId: 'local')..hello();
    await _settle();
    await _settle();
    expect(remoteGuest.snapshot, isNotNull, reason: 'участник по сети получил состояние');
    expect(local.snapshot, isNotNull, reason: 'устройство тира получило состояние по Bluetooth');
    local.shoot('u_a', 1, 1);
    await _settle();
    await _settle();
    expect(c.stagedOf('u_a').length, 1, reason: 'выстрел с устройства тира дошёл до ведущего');
    host.dispose();
    hub.close();
  });
}
