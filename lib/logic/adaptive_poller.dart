import 'dart:async';

/// Интервал опроса сервера, который подстраивается сам.
///
/// Зачем: фиксированные 10–20 секунд либо слишком редко для живой
/// переписки, либо слишком часто, когда никто ничего не пишет — тысяча
/// пользователей с открытым чатом давала бы десятки запросов в секунду
/// впустую. Правила:
/// * пришло новое или человек только что действовал ([nudge]) — опрашиваем
///   часто ([min]);
/// * ничего нового — интервал растёт в 1.5 раза за опрос до [max];
/// * сервер отвечает медленно или с ошибкой — общий множитель нагрузки
///   удваивается (до [maxLoad]), быстро отвечает — плавно снижается.
///   Это защита базы: чем ей тяжелее, тем реже мы её дёргаем.
/// * [scale] — удалённый рычаг (см. `RemoteConfig.pollScale`): разработчик
///   может замедлить всех клиентов разом, не выпуская новую версию.
class AdaptivePoller {
  AdaptivePoller({
    this.min = const Duration(seconds: 5),
    this.max = const Duration(seconds: 60),
    double Function()? scale,
  })  : scale = scale ?? _one,
        _base = min;

  static double _one() => 1.0;

  final Duration min;
  final Duration max;
  final double Function() scale;

  /// Ответ дольше — считаем сервер загруженным.
  static const Duration slowLatency = Duration(seconds: 2);

  /// Ответ быстрее — нагрузка в норме, множитель можно снижать.
  static const Duration fastLatency = Duration(milliseconds: 700);
  static const double maxLoad = 8;

  Duration _base;
  double _load = 1;

  double get load => _load;

  Duration get interval {
    final ms = (_base.inMilliseconds * _load).round();
    final clamped = ms.clamp(min.inMilliseconds, max.inMilliseconds);
    final s = scale().clamp(0.25, 20.0);
    return Duration(milliseconds: (clamped * s).round());
  }

  /// Итог одного опроса. [gotNew] — пришло что-то новое.
  void onResult({required Duration latency, required bool ok, required bool gotNew}) {
    if (!ok || latency > slowLatency) {
      _load = (_load * 2).clamp(1, maxLoad).toDouble();
    } else if (latency < fastLatency) {
      _load = (_load - 0.25).clamp(1, maxLoad).toDouble();
    }
    if (gotNew) {
      _base = min;
    } else {
      final grown = (_base.inMilliseconds * 1.5).round();
      _base = Duration(milliseconds: grown.clamp(min.inMilliseconds, max.inMilliseconds));
    }
  }

  /// Человек что-то сделал (написал, пришёл push) — ждать долго незачем.
  void nudge() => _base = min;
}

/// Самозапускающийся цикл опроса поверх [AdaptivePoller]: следующий
/// опрос назначается только ПОСЛЕ окончания предыдущего (запросы не
/// накладываются даже при медленном сервере), а интервал берётся заново
/// каждый раз.
class PollLoop {
  PollLoop({required this.poller, required this.tick});

  final AdaptivePoller poller;

  /// Один опрос; `true` — пришло что-то новое.
  final Future<bool> Function() tick;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    _schedule();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Опросить немедленно (например, по push) и вернуть частый режим.
  void poke() {
    if (!_running) return;
    poller.nudge();
    _timer?.cancel();
    _run();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(poller.interval, _run);
  }

  Future<void> _run() async {
    if (!_running) return;
    if (_busy) {
      _schedule();
      return;
    }
    _busy = true;
    final watch = Stopwatch()..start();
    var ok = true;
    var gotNew = false;
    try {
      gotNew = await tick();
    } catch (_) {
      ok = false;
    }
    watch.stop();
    _busy = false;
    poller.onResult(latency: watch.elapsed, ok: ok, gotNew: gotNew);
    if (_running) _schedule();
  }
}
