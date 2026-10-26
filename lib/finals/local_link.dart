import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'finals_net.dart';

/// Байтовый канал между двумя устройствами одного тира (Bluetooth, Wi-Fi тира…). Само по себе ничего не знает про
/// финалы: только отдаёт и принимает порции байт порядком отправки. Конкретная связь (Bluetooth на Android, Wi-Fi
/// и т. п.) реализует этот интерфейс, остальное — кадрирование, мост и финал — уже работает поверх него.
abstract class LocalLink {
  void Function(Uint8List data)? onData;
  void Function()? onClosed;
  bool get isOpen;

  /// Сколько байт можно отправить за раз (у Bluetooth — размер пакета минус служебные байты).
  int get maxPacket;
  Future<bool> send(Uint8List data);
  void close();
}

/// Кадрирование: сообщение финала (JSON) не помещается в один пакет Bluetooth, поэтому режется на кадры.
/// Кадр = [номер сообщения (1 байт), номер части (2 байта), всего частей (2 байта)] + часть данных. Принимающая сторона собирает сообщение
/// из частей; потерянное или оборванное сообщение отбрасывается целиком (следующее состояние придёт само).
class MessageFramer {
  MessageFramer({this.maxPacket = 180});

  /// Размер пакета канала; на данные в кадре остаётся на пять байт меньше.
  final int maxPacket;

  static const int maxParts = 65535;
  static const int header = 5;
  int _next = 0;
  int? _curId;
  int _curTotal = 0;
  final Map<int, Uint8List> _parts = {};

  /// Режет сообщение на кадры. `null` — не помещается (пакет слишком мал или кадров больше [maxParts]).
  List<Uint8List>? encode(String event, Map<String, dynamic> payload) {
    final body = utf8.encode(jsonEncode({'e': event, 'p': payload}));
    final chunk = maxPacket - header;
    if (chunk <= 0) return null;
    final total = (body.length / chunk).ceil().clamp(1, 1 << 30);
    if (total > maxParts) return null;
    final id = _next;
    _next = (_next + 1) & 0xFF;
    return [
      for (var i = 0; i < total; i++)
        Uint8List.fromList([
          id,
          i >> 8,
          i & 0xFF,
          total >> 8,
          total & 0xFF,
          ...body.sublist(i * chunk, ((i + 1) * chunk).clamp(0, body.length)),
        ]),
    ];
  }

  /// Принимает кадр; когда сообщение собрано целиком, вызывает [onMessage].
  void feed(Uint8List frame, void Function(String event, Map<String, dynamic> payload) onMessage) {
    if (frame.length < header) return;
    final id = frame[0], idx = (frame[1] << 8) | frame[2], total = (frame[3] << 8) | frame[4];
    if (total == 0 || idx >= total) return;
    if (_curId != id) {
      // Началось новое сообщение — недособранное прошлое теряем.
      _curId = id;
      _curTotal = total;
      _parts.clear();
    }
    if (total != _curTotal) return;
    _parts[idx] = Uint8List.sublistView(frame, header);
    if (_parts.length < total) return;
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      all.add(_parts[i]!);
    }
    _parts.clear();
    _curId = null;
    try {
      final j = jsonDecode(utf8.decode(all.takeBytes())) as Map<String, dynamic>;
      onMessage('${j['e']}', (j['p'] as Map).cast<String, dynamic>());
    } catch (_) {
      // испорченное сообщение пропускаем
    }
  }
}

/// Канал финала поверх локальной связи: те же `send/onMessage`, что у realtime-канала, поэтому гость и ведущий
/// не знают, по чему идёт связь.
class LocalLinkChannel implements FinalsChannel {
  LocalLinkChannel(this.link) : _framer = MessageFramer(maxPacket: link.maxPacket) {
    link.onData = (d) => _framer.feed(d, (e, p) => onMessage?.call(e, p));
    link.onClosed = () => onClosed?.call();
  }

  final LocalLink link;
  final MessageFramer _framer;

  @override
  void Function(String event, Map<String, dynamic> payload)? onMessage;
  @override
  void Function()? onClosed;

  @override
  Future<bool> join() async => link.isOpen;

  @override
  bool send(String event, Map<String, dynamic> payload) {
    if (!link.isOpen) return false;
    final frames = _framer.encode(event, payload);
    if (frames == null) return false;
    for (final f in frames) {
      unawaited(link.send(f));
    }
    return true;
  }

  @override
  void close() => link.close();
}

/// Пара связанных каналов в памяти — для тестов и отладки без железа. [maxPacket] проверяет кадрирование.
class MemoryLocalLink implements LocalLink {
  MemoryLocalLink._(this.maxPacket);

  static (MemoryLocalLink, MemoryLocalLink) pair({int maxPacket = 20}) {
    final a = MemoryLocalLink._(maxPacket), b = MemoryLocalLink._(maxPacket);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  MemoryLocalLink? _peer;
  bool _open = true;

  @override
  final int maxPacket;
  @override
  void Function(Uint8List data)? onData;
  @override
  void Function()? onClosed;

  @override
  bool get isOpen => _open;

  @override
  Future<bool> send(Uint8List data) async {
    if (!_open) return false;
    final peer = _peer;
    scheduleMicrotask(() => peer?.onData?.call(Uint8List.fromList(data)));
    return true;
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    onClosed?.call();
    final p = _peer;
    if (p != null && p._open) {
      p._open = false;
      p.onClosed?.call();
    }
  }
}
