import 'dart:async';

/// Секундомер финала без накопления ошибки: считает целые секунды по часам устройства (Stopwatch), а не по числу
/// срабатываний таймера. Если приложение приглушили или связь/процессор «подвисли», пропущенные секунды
/// догоняются подряд — 5 минут остаются пятью минутами, а не растягиваются в 6 или сжимаются в 4.
class SecondTicker {
  SecondTicker(this.onSecond, {Duration Function()? now, this.maxCatchUp = 600}) : _now = now ?? _systemNow;

  final void Function() onSecond;
  final Duration Function() _now;

  /// Больше стольких секунд за раз не догоняем (устройство спало — финал не «перематываем» на часы вперёд).
  final int maxCatchUp;

  Timer? _timer;
  Duration? _start;
  int _counted = 0;

  static final Stopwatch _sw = Stopwatch()..start();
  static Duration _systemNow() => _sw.elapsed;

  /// Запускает отсчёт; проверка 5 раз в секунду.
  void start() {
    cancel();
    _start = _now();
    _counted = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => poll());
  }

  /// Отдаёт [onSecond] за каждую целую секунду, прошедшую с запуска и ещё не отданную.
  void poll() {
    final start = _start;
    if (start == null) return;
    final whole = (_now() - start).inSeconds;
    var due = whole - _counted;
    if (due <= 0) return;
    if (due > maxCatchUp) {
      _counted = whole - maxCatchUp; // слишком долго спали: отдаём только последние maxCatchUp секунд
      due = maxCatchUp;
    }
    for (var i = 0; i < due; i++) {
      _counted++;
      onSecond();
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _start = null;
  }
}
