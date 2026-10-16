import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/p2p_file_transfer.dart';

/// Два конца, соединённые «проводом» в памяти (кадры доставляются асинхронно).
class _Wire {
  late final P2pFiles a, b;
  bool cut = false;
  _Wire(Directory dirA, Directory dirB) {
    a = P2pFiles(send: (e, p) => _deliver(b, e, p), dirFor: () async => dirA);
    b = P2pFiles(send: (e, p) => _deliver(a, e, p), dirFor: () async => dirB);
  }
  bool _deliver(P2pFiles to, String e, Map<String, dynamic> p) {
    if (cut) return false;
    final copy = Map<String, dynamic>.from(p);
    scheduleMicrotask(() => to.handle(e, copy));
    return true;
  }
}

Future<void> _until(bool Function() cond, {int ms = 8000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('p2p_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File makeFile(String name, int size) {
    final f = File('${tmp.path}/$name');
    final rnd = math.Random(7);
    f.writeAsBytesSync(List<int>.generate(size, (_) => rnd.nextInt(256)));
    return f;
  }

  test('файл 3 МБ + хвост доходит целиком, хеш совпадает, прогресс 100%', () async {
    final src = makeFile('video.mp4', 3 * 1024 * 1024 + 123);
    final wire = _Wire(Directory('${tmp.path}/a'), Directory('${tmp.path}/b'));
    wire.b.onOffer = (r) => r.accept();
    final s = wire.a.sendFile(path: src.path, name: 'video.mp4', size: src.lengthSync(), mime: 'video/mp4');
    await _until(() => s.finished);
    expect(s.state.value, P2pState.done);
    expect(s.progress.value, 1.0);
    final r = wire.b.receivers.values.single;
    expect(r.state.value, P2pState.done);
    expect(File(r.path!).readAsBytesSync(), src.readAsBytesSync());
  });

  test('получатель отказался — отправитель получает «отказ», ничего не пишется', () async {
    final src = makeFile('a.bin', 50000);
    final wire = _Wire(Directory('${tmp.path}/a'), Directory('${tmp.path}/b'));
    wire.b.onOffer = (r) => r.reject();
    final s = wire.a.sendFile(path: src.path, name: 'a.bin', size: 50000, mime: 'application/octet-stream');
    await _until(() => s.finished);
    expect(s.state.value, P2pState.rejected);
    expect(Directory('${tmp.path}/b').existsSync() ? Directory('${tmp.path}/b').listSync() : [], isEmpty);
  });

  test('опасное расширение блокируется получателем без приёма', () async {
    final src = makeFile('setup.exe', 1000);
    final wire = _Wire(Directory('${tmp.path}/a'), Directory('${tmp.path}/b'));
    wire.b.onOffer = (r) => r.accept();
    final s = wire.a.sendFile(path: src.path, name: 'setup.exe', size: 1000, mime: 'application/octet-stream');
    await _until(() => s.finished);
    expect(s.state.value, P2pState.rejected);
  });

  test('обрыв связи посередине: обе стороны в «ошибке», недокачанный файл удалён', () async {
    final src = makeFile('big.dat', 2 * 1024 * 1024);
    final wire = _Wire(Directory('${tmp.path}/a'), Directory('${tmp.path}/b'));
    wire.b.onOffer = (r) => r.accept();
    final s = wire.a.sendFile(path: src.path, name: 'big.dat', size: src.lengthSync(), mime: 'application/octet-stream');
    await _until(() => s.progress.value > 0.1);
    wire.cut = true;
    await Future.wait([wire.a.abortAll(), wire.b.abortAll()]);
    expect(s.state.value, P2pState.failed);
    final r = wire.b.receivers.values.single;
    expect(r.state.value, P2pState.failed);
    expect(File(r.path!).existsSync(), isFalse);
  });
}
