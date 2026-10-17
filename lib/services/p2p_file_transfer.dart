import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../logic/attachment_guard.dart';
import '../logic/chat_media_utils.dart';

/// Передача больших файлов напрямую между двумя устройствами по каналу данных
/// WebRTC (P2P), без базы и без облака. Файл читается и пишется частями прямо
/// на диске, в память целиком не попадает; размер не ограничен (только
/// свободное место). Поток управляется окном подтверждений: отправитель не
/// уходит дальше чем на [window] частей от последнего подтверждённого.
///
/// Кадры (имя события → полезная нагрузка), все идут по P2P-каналу:
///  * `file_offer`  {id,name,size,mime,chunks}   отправитель → получатель
///  * `file_accept` / `file_reject` {id}          получатель → отправитель
///  * `file_chunk`  {id,i,d}                      часть i в base64
///  * `file_ack`    {id,n}                        принято подряд n частей
///  * `file_done`   {id,sha}                      отправитель: всё отправлено
///  * `file_ok` / `file_bad` {id}                 получатель: проверка прошла / нет
///  * `file_cancel` {id}                          любая сторона
enum P2pState { offered, active, done, failed, rejected, cancelled }

typedef P2pSend = bool Function(String event, Map<String, dynamic> payload);

const _uuid = Uuid();

/// Приёмник итогового хеша для поточного SHA-256.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Размер одной части (до base64). Небольшой, чтобы влезать в сообщение канала.
const int p2pChunkSize = 8 * 1024;

/// Сколько частей можно отправить без подтверждения.
const int p2pWindow = 48;

/// Подтверждение каждые столько принятых частей.
const int p2pAckEvery = 16;

class P2pSender {
  P2pSender({required this.path, required this.name, required this.size, required this.mime, required this.send, String? id, this.meta})
      : id = id ?? _uuid.v4(),
        chunks = (size / p2pChunkSize).ceil();

  final String id;
  final String path;
  final String name;
  final int size;
  final String mime;
  final int chunks;
  final P2pSend send;

  /// Доп. данные для получателя (вложение переписки: тип, подпись, ответ).
  final Map<String, dynamic>? meta;

  final progress = ValueNotifier<double>(0);
  final state = ValueNotifier<P2pState>(P2pState.offered);
  String? error;

  RandomAccessFile? _raf;
  int _next = 0;
  int _acked = 0;
  bool _pumping = false;
  final _digest = _DigestSink();
  ByteConversionSink? _hash;

  bool get finished => state.value == P2pState.done || state.value == P2pState.failed || state.value == P2pState.rejected || state.value == P2pState.cancelled;

  bool offer() {
    final ok = send('file_offer', {'id': id, 'name': name, 'size': size, 'mime': mime, 'chunks': chunks, if (meta != null) 'meta': meta});
    if (!ok) _fail('нет прямого соединения');
    return ok;
  }

  void handle(String event, Map<String, dynamic> p) {
    if (p['id'] != id || finished) return;
    switch (event) {
      case 'file_accept':
        state.value = P2pState.active;
        _start();
      case 'file_reject':
        state.value = P2pState.rejected;
        _close();
      case 'file_ack':
        final n = (p['n'] as num?)?.toInt() ?? 0;
        if (n > _acked) _acked = n;
        progress.value = chunks == 0 ? 1 : _acked / chunks;
        _pump();
      case 'file_ok':
        progress.value = 1;
        state.value = P2pState.done;
        _close();
      case 'file_bad':
        _fail('получатель не принял файл (проверка не прошла)');
      case 'file_cancel':
        state.value = P2pState.cancelled;
        _close();
    }
  }

  void cancel() {
    if (finished) return;
    send('file_cancel', {'id': id});
    state.value = P2pState.cancelled;
    _close();
  }

  /// Соединение оборвалось.
  void abort() => _fail('связь прервана');

  Future<void> _start() async {
    try {
      _raf = await File(path).open();
      _hash = sha256.startChunkedConversion(_digest);
      await _pump();
    } catch (e) {
      _fail('не удалось прочитать файл');
    }
  }

  Future<void> _pump() async {
    if (_pumping || _raf == null || state.value != P2pState.active) return;
    _pumping = true;
    try {
      while (_next < chunks && _next - _acked < p2pWindow && state.value == P2pState.active) {
        final len = math.min(p2pChunkSize, size - _next * p2pChunkSize);
        final buf = await _raf!.read(len);
        if (buf.length != len) throw StateError('файл изменился');
        _hash!.add(buf);
        if (!send('file_chunk', {'id': id, 'i': _next, 'd': base64Encode(buf)})) {
          _fail('связь прервана');
          return;
        }
        _next++;
      }
      if (_next == chunks && !_doneSent && state.value == P2pState.active) {
        _doneSent = true;
        _hash!.close();
        send('file_done', {'id': id, 'sha': _digest.value.toString()});
      }
    } catch (e) {
      _fail('ошибка чтения файла');
    } finally {
      _pumping = false;
      if (finished) _close();
    }
  }

  bool _doneSent = false;

  void _fail(String why) {
    if (finished) return;
    error = why;
    state.value = P2pState.failed;
    _close();
  }

  /// Файл закрываем, когда не идёт чтение (иначе «async operation is pending»).
  void _close() {
    if (_pumping) return; // _pump закроет сам в finally
    final r = _raf;
    _raf = null;
    r?.close().catchError((Object _) => r);
  }
}

class P2pReceiver {
  P2pReceiver({required this.id, required this.name, required this.size, required this.mime, required this.chunks, required this.send, required this.dir, this.meta});

  final String id;
  final String name;
  final int size;
  final String mime;
  final int chunks;
  final P2pSend send;
  final Directory dir;
  final Map<String, dynamic>? meta;

  final progress = ValueNotifier<double>(0);
  final state = ValueNotifier<P2pState>(P2pState.offered);
  String? error;
  String? path;

  RandomAccessFile? _raf;
  int _expected = 0;
  final _digest = _DigestSink();
  ByteConversionSink? _hash;
  String? _senderSha;
  bool _closing = false;

  bool get finished => state.value == P2pState.done || state.value == P2pState.failed || state.value == P2pState.rejected || state.value == P2pState.cancelled;

  Future<void> accept() async {
    final verdict = AttachmentGuard.checkName(name);
    if (!verdict.ok) {
      reject();
      error = verdict.reason;
      return;
    }
    try {
      await dir.create(recursive: true);
      path = p.join(dir.path, '${id.substring(0, 8)}_${ChatMediaUtils.safePathSegment(name)}');
      _raf = await File(path!).open(mode: FileMode.write);
      _hash = sha256.startChunkedConversion(_digest);
      state.value = P2pState.active;
      if (!send('file_accept', {'id': id})) _fail('нет прямого соединения');
    } catch (_) {
      _fail('не удалось создать файл');
    }
  }

  void reject() {
    if (finished) return;
    send('file_reject', {'id': id});
    state.value = P2pState.rejected;
  }

  void cancel() {
    if (finished) return;
    send('file_cancel', {'id': id});
    _discard(P2pState.cancelled);
  }

  Future<void> abort() => _fail('связь прервана');

  Future<void> _queue = Future<void>.value();

  /// Кадры обрабатываются строго по очереди: запись в один файл не должна
  /// идти параллельно, а счётчик частей — обгонять запись.
  Future<void> handle(String event, Map<String, dynamic> m) {
    _queue = _queue.then((_) => _handle(event, m)).catchError((Object _) => _fail('ошибка записи файла'));
    return _queue;
  }

  Future<void> _handle(String event, Map<String, dynamic> m) async {
    if (m['id'] != id || finished) return;
    switch (event) {
      case 'file_chunk':
        if (state.value != P2pState.active || _raf == null) return;
        final i = (m['i'] as num?)?.toInt() ?? -1;
        if (i != _expected) return; // канал упорядоченный; чужое/повтор игнорируем
        final Uint8List bytes;
        try {
          bytes = base64Decode('${m['d']}');
        } catch (_) {
          return;
        }
        _hash!.add(bytes);
        await _raf!.writeFrom(bytes);
        _expected++;
        progress.value = chunks == 0 ? 1 : _expected / chunks;
        if (_expected % p2pAckEvery == 0 || _expected == chunks) send('file_ack', {'id': id, 'n': _expected});
        await _maybeFinish();
      case 'file_done':
        _senderSha = '${m['sha']}';
        await _maybeFinish();
      case 'file_cancel':
        _discard(P2pState.cancelled);
    }
  }

  Future<void> _maybeFinish() async {
    if (_closing || _expected != chunks || _senderSha == null || state.value != P2pState.active) return;
    _closing = true;
    _hash!.close();
    await _raf?.close();
    _raf = null;
    final okSha = _digest.value.toString() == _senderSha;
    final okSize = await File(path!).length() == size;
    final verdict = (okSha && okSize) ? await AttachmentGuard.checkFile(path!, name) : null;
    if (okSha && okSize && verdict != null && verdict.ok) {
      progress.value = 1;
      state.value = P2pState.done;
      send('file_ok', {'id': id});
    } else {
      send('file_bad', {'id': id});
      error = verdict != null && !verdict.ok ? verdict.reason : 'файл повреждён при передаче';
      _discard(P2pState.failed);
    }
  }

  Future<void> _fail(String why) {
    if (finished) return Future<void>.value();
    error = why;
    return _discard(P2pState.failed);
  }

  /// Остановить: новые кадры сразу игнорируются, а файл закрывается и
  /// удаляется после текущей записи (не вовремя закрыть нельзя).
  Future<void> _discard(P2pState to) {
    state.value = to;
    _queue = _queue.then((_) async {
      final r = _raf;
      _raf = null;
      try {
        await r?.close();
      } catch (_) {}
      final f = path;
      if (f != null) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
    });
    return _queue;
  }
}

/// Все передачи одного диалога. Живёт рядом с P2P-линком `LiveChatSession`.
class P2pFiles {
  P2pFiles({required this.send, required this.dirFor});

  /// Отправка кадра по P2P (`false`, если канал не открыт).
  final P2pSend send;

  /// Куда складывать принятые файлы.
  final Future<Directory> Function() dirFor;

  final senders = <String, P2pSender>{};
  final receivers = <String, P2pReceiver>{};

  /// Пришло предложение файла: показать запрос «Принять?».
  void Function(P2pReceiver r)? onOffer;

  /// Передача изменилась (прогресс/итог) — для перерисовки.
  void Function()? onChanged;

  /// Фоновая служба: (есть ли активные передачи, подпись, средний прогресс).
  /// Вызывается при каждом изменении; `false` — службу можно останавливать.
  void Function(bool active, String text, double progress)? onBackground;

  /// Идёт ли сейчас хоть одна передача (чтобы не закрывать P2P-соединение).
  bool get hasActive =>
      senders.values.any((s) => !s.finished && s.state.value == P2pState.active) ||
      receivers.values.any((r) => !r.finished && r.state.value == P2pState.active);

  void _changed() {
    onChanged?.call();
    final act = <(String, double)>[
      for (final s in senders.values)
        if (!s.finished && s.state.value == P2pState.active) (s.name, s.progress.value),
      for (final r in receivers.values)
        if (!r.finished && r.state.value == P2pState.active) (r.name, r.progress.value),
    ];
    if (act.isEmpty) {
      onBackground?.call(false, '', 0);
    } else {
      final avg = act.fold<double>(0, (a, e) => a + e.$2) / act.length;
      final text = act.length == 1
          ? '${act.first.$1} — ${(act.first.$2 * 100).round()}%'
          : 'Файлов: ${act.length} — ${(avg * 100).round()}%';
      onBackground?.call(true, text, avg);
    }
  }

  static bool isFileEvent(String e) => e.startsWith('file_');

  P2pSender sendFile(
      {required String path, required String name, required int size, required String mime, String? id, Map<String, dynamic>? meta}) {
    final s = P2pSender(path: path, name: name, size: size, mime: mime, send: send, id: id, meta: meta);
    senders[s.id] = s;
    s.state.addListener(_changed);
    s.progress.addListener(_changed);
    s.offer();
    return s;
  }

  Future<void> handle(String event, Map<String, dynamic> p) async {
    final id = '${p['id']}';
    switch (event) {
      case 'file_offer':
        if (receivers.containsKey(id)) return;
        final r = P2pReceiver(
          id: id,
          name: '${p['name']}',
          size: (p['size'] as num?)?.toInt() ?? 0,
          mime: '${p['mime'] ?? 'application/octet-stream'}',
          chunks: (p['chunks'] as num?)?.toInt() ?? 0,
          send: send,
          dir: await dirFor(),
          meta: p['meta'] is Map ? (p['meta'] as Map).cast<String, dynamic>() : null,
        );
        receivers[id] = r;
        r.state.addListener(_changed);
        r.progress.addListener(_changed);
        onOffer?.call(r);
      case 'file_accept' || 'file_reject' || 'file_ack' || 'file_ok' || 'file_bad':
        senders[id]?.handle(event, p);
      case 'file_chunk' || 'file_done':
        await receivers[id]?.handle(event, p);
      case 'file_cancel':
        senders[id]?.handle(event, p);
        await receivers[id]?.handle(event, p);
    }
  }

  /// Соединение оборвалось: активные передачи останавливаем (файлы-огрызки удаляются).
  Future<void> abortAll() async {
    for (final s in senders.values) {
      s.abort();
    }
    await Future.wait([for (final r in receivers.values) r.abort()]);
  }
}
