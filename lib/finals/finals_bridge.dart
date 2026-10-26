import 'finals_net.dart';

/// Мост тира: устройство, которое держит связь с ведущим через базу (realtime) и раздаёт состояние остальным
/// устройствам своего тира по локальной связи (Bluetooth и т. п.). Остальным устройствам тира сеть не нужна.
///
/// Сообщения локальных устройств уходят к ведущему как есть (с их собственными токенами в `author`), поэтому
/// ведущий видит их как обычных участников, а их «признаки жизни» (`ping`) отражают и связь с мостом.
/// Состояние ведущего (`state`, `ended`, `denied`, кричалки) мост пересылает локальным устройствам.
/// Последнее состояние хранится: подключившееся к мосту устройство получает его сразу, не дожидаясь ведущего,
/// а при обрыве канала к базе локальные устройства продолжают видеть последнее известное состояние.
class FinalsBridge {
  /// [hostMode] — устройство ведущего: сообщения локальных устройств идут ему самому (а не «наверх»), а его
  /// состояние уходит и в базу, и всем локальным устройствам. Иначе — мост гостя: локальные ↔ ведущий через базу.
  FinalsBridge(this.upstream, {this.hostMode = false}) {
    upstream.onMessage = _fromUpstream;
  }

  final bool hostMode;

  /// Канал к ведущему (realtime).
  final FinalsChannel upstream;

  final List<FinalsChannel> _locals = [];
  Map<String, dynamic>? _lastState;

  /// Канал самого устройства-моста как участника финала (его собственный экран): работает как обычный канал.
  late final FinalsChannel self = _SelfChannel(this);

  int get localCount => _locals.length;

  /// Подключает локальное устройство (принятое Bluetooth-соединение).
  void addLocal(FinalsChannel local) {
    _locals.add(local);
    local.onMessage = (e, p) => _fromLocal(local, e, p);
    local.onClosed = () => _locals.remove(local);
    final s = _lastState;
    if (s != null) local.send('state', s); // сразу отдаём последнее известное состояние
  }

  void _fromUpstream(String event, Map<String, dynamic> p) {
    if (hostMode) {
      self.onMessage?.call(event, p); // участники по сети — ведущему
      return;
    }
    if (event == 'state') _lastState = p;
    for (final l in List.of(_locals)) {
      l.send(event, p);
    }
    self.onMessage?.call(event, p);
  }

  bool _fromSelf(String event, Map<String, dynamic> p) {
    final ok = upstream.send(event, p);
    if (hostMode) {
      for (final l in List.of(_locals)) {
        l.send(event, p);
      }
    }
    return ok || (hostMode && _locals.isNotEmpty);
  }

  void _fromLocal(FinalsChannel from, String event, Map<String, dynamic> p) {
    if (hostMode) {
      self.onMessage?.call(event, p); // устройства тира ведущего — самому ведущему
      return;
    }
    // Привет от локального устройства: ему сразу отвечаем кешем, и всё равно передаём ведущему (он узнаёт участника).
    if (event == 'hello' && _lastState != null) from.send('state', _lastState!);
    upstream.send(event, p);
  }

  void close() {
    for (final l in List.of(_locals)) {
      l.close();
    }
    _locals.clear();
    upstream.close();
  }
}

class _SelfChannel implements FinalsChannel {
  _SelfChannel(this._bridge);
  final FinalsBridge _bridge;

  @override
  void Function(String event, Map<String, dynamic> payload)? onMessage;
  @override
  void Function()? onClosed;

  @override
  Future<bool> join() async => true;

  @override
  bool send(String event, Map<String, dynamic> payload) => _bridge._fromSelf(event, payload);

  @override
  void close() => _bridge.close();
}
